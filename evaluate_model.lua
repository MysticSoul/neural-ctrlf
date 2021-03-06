require 'torch'
require 'nn'
require 'cunn'
require 'dpnn'
require 'cudnn'
require 'hdf5'

require 'ctrlfnet.DataLoader'
require 'ctrlfnet.WordSpottingModel'

utils = require 'ctrlfnet.utils'
box_utils = require 'ctrlfnet.box_utils'

--[[
Evaluate a trained CtrlFNet model by running it on a split on the data.
--]]

cmd = torch.CmdLine()
cmd:option('-dataset', 'washington', 'The HDF5 file to load data from; optional.')
cmd:option('-dataset_path', 'data/dbs/', 'HDF5 file containing the preprocessed dataset (from proprocess.py)')
cmd:option('-checkpoint_path', 'checkpoints/', 'HDF5 file containing the preprocessed dataset (from proprocess.py)')
cmd:option('-gpu', 0, 'The GPU to use')
cmd:option('-use_cudnn', 1, 'Whether to use cuDNN backend in GPU mode.')
cmd:option('-split', 'test', 'Which split to evaluate; either val or test.')
cmd:option('-folds', 1, 'How many folds to use')
cmd:option('-rpn_nms_thresh', 0.7)
cmd:option('-embedding', 'dct', 'which embedding to use')
cmd:option('-final_nms_thresh', -1)
cmd:option('-num_proposals', -1, 'How many proposals to use with the RPN, default = the same as the DTP')
opt = cmd:parse(arg)

cutorch.setDevice(opt.gpu + 1) -- note +1 because lua is 1-indexed

models = {
  'ctrlfnet_washington_fold1_best.t7',
  'ctrlfnet_washington_fold2_best.t7',
  'ctrlfnet_washington_fold3_best.t7',
  'ctrlfnet_washington_fold4_best.t7'
}

embedding_size = 108

split = opt.split
split_to_int = {train=0, val=1, test=2}
split = split_to_int[split]

h5_out = 'descriptors/' .. opt.dataset .. '_' .. opt.embedding .. '_descriptors.h5'
print("Started writing to " .. h5_out)
h5_file = hdf5.open(h5_out, 'w')

local dataset_original = opt.dataset
for fold = 1, opt.folds do 
  opt.dataset = dataset_original .. '_fold' .. fold
  loader = DataLoader(opt)
  
  checkpoint = torch.load(opt.checkpoint_path .. models[fold])
  print('Loaded model ' .. models[fold])
  model = checkpoint.model
  model:setTestArgs(opt)
  model:evaluate()
  model.timing = false
  model.dump_vars = false
  model.cnn_backward = false
  loader:resetIterator(split)

  local counter = 0
  all_losses = {}
  all_boxes = {}
  all_logprobs = {}
  all_embeddings = {}
  all_gt_embeddings = {}
  all_gt_scores = {}
  all_gt_boxes = {}
  all_rp_embeddings = {}
  all_rp_scores = {}
  all_region_proposals = {}
  btoi = {}
  rptoi = {}

  local j = 1 -- never, EVER change to 0 instead of 1 for j & k
  local k = 1

  extract_rpn_scores = 0
  apply = nn.ApplyBoxTransform():cuda()

  while true do
    counter = counter + 1
    
    -- Grab a batch of data and convert it to the right dtype
    loader_kwargs = {split=split, iterate=true}
    img, gt_boxes, region_proposals, gte, labels, info = loader:getBatch(loader_kwargs)

    data = {image = img:cuda(), gt_boxes = gt_boxes:cuda(), embeddings = gte:cuda(), labels=labels:cuda()}

    im_size = data.image:size()
    rp_size = region_proposals[1]:size()
  	opt.num_proposals = rp_size[1]
	
    feature_maps = model.nets.conv_net2:forward(model.nets.conv_net1:forward(data.image))

    if extract_rpn_scores then
      rpn_out = model.nets.localization_layer.nets.rpn:forward(feature_maps)
      rpn_boxes, rpn_anchors = rpn_out[1], rpn_out[2]
      rpn_trans, rpn_scores = rpn_out[3], rpn_out[4]
      num_boxes = rpn_boxes:size(2)

      bounds = {
        x_min=1, y_min=1,
        x_max=im_size[4], --image_width,
        y_max=im_size[3], --image_height
      }
      rpn_boxes, valid = box_utils.clip_boxes(rpn_boxes, bounds, 'xcycwh')

      function clamp_data(data)
        -- data should be 1 x kHW x D
        -- valid is byte of shape kHW
        assert(data:size(1) == 1, 'must have 1 image per batch')
        assert(data:dim() == 3)
        local mask = valid:view(1, -1, 1):expandAs(data)
        return data[mask]:view(1, -1, data:size(3))
      end
      rpn_boxes = clamp_data(rpn_boxes)
      rpn_anchors = clamp_data(rpn_anchors)
      rpn_trans = clamp_data(rpn_trans)
      rpn_scores = clamp_data(rpn_scores)
      num_boxes = rpn_boxes:size(2)

      rpn_boxes_x1y1x2y2 = box_utils.xcycwh_to_x1y1x2y2(rpn_boxes)

      -- Convert objectness positive / negative scores to probabilities
      rpn_scores_exp = torch.exp(rpn_scores)
      pos_exp = rpn_scores_exp[{1, {}, 1}]
      neg_exp = rpn_scores_exp[{1, {}, 2}]
      scores = (pos_exp + neg_exp):pow(-1):cmul(pos_exp)

      boxes_scores = scores.new(num_boxes, 5)
      boxes_scores[{{}, {1, 4}}] = rpn_boxes_x1y1x2y2
      boxes_scores[{{}, 5}] = scores
      idx = box_utils.nms(boxes_scores, opt.rpn_nms_thresh, opt.num_proposals)

      rpn_boxes_nms = rpn_boxes:index(2, idx)[1]
      rpn_anchors_nms = rpn_anchors:index(2, idx)[1]
      rpn_trans_nms = rpn_trans:index(2, idx)[1]
      rpn_scores_nms = rpn_scores:index(2, idx)[1]
      scores_nms = scores:index(1, idx)
    end
	
    batch_size = 1024
	
    -- Extract embeddings for gt_boxes manually
    gt_boxes = gt_boxes[1]:cuda()
    model.nets.localization_layer.nets.roi_pooling:setImageSize(im_size[3], im_size[4])
    roi_features = model.nets.localization_layer.nets.roi_pooling:forward{feature_maps[1], gt_boxes}
    roi_features = model.nets.recog_base:forward(roi_features)
    gt_embeddings = model.nets.embedding_net:forward(roi_features)  
    gt_scores = model.nets.objectness_branch:forward(roi_features)

    gt_boxes =  box_utils.xcycwh_to_x1y1x2y2(gt_boxes)
    table.insert(all_gt_embeddings, gt_embeddings:float())
    table.insert(all_gt_boxes, gt_boxes:float())
    table.insert(all_gt_scores, gt_scores:float())

	-- Extract embeddings for rpn_boxes in batches
	boxes = torch.FloatTensor(opt.num_proposals, 4)
	embeddings = torch.FloatTensor(opt.num_proposals, embedding_size)
	logprobs = torch.FloatTensor(opt.num_proposals, 1)
	box_split = boxes:split(batch_size)
	emb_split = embeddings:split(batch_size)
    lp_split = logprobs:split(batch_size)
	
	for iv,v in ipairs(rpn_boxes_nms:split(batch_size)) do
      model.nets.localization_layer.nets.roi_pooling:setImageSize(im_size[3], im_size[4])
      roi_features = model.nets.localization_layer.nets.roi_pooling:forward{feature_maps[1], v}
      roi_features = model.nets.recog_base:forward(roi_features)
      emb = model.nets.embedding_net:forward(roi_features)  
      lp = model.nets.objectness_branch:forward(roi_features)
      box_trans = model.nets.box_reg_branch:forward(roi_features)
      box = apply:forward({v, box_trans})

      emb_split[iv]:copy(emb:float())
      lp_split[iv]:copy(lp:float())
      box_split[iv]:copy(box:float())
    end
    boxes = box_utils.xcycwh_to_x1y1x2y2(boxes)
    table.insert(all_boxes, boxes:float())
    table.insert(all_logprobs, logprobs:float())
    table.insert(all_embeddings, embeddings:float())
	
    -- Extract embeddings for external region proposals
    region_proposals = region_proposals[1]:cuda()

    rp_size = region_proposals:size()
    rp_embeddings = torch.FloatTensor(rp_size[1], embedding_size)
    rp_scores = torch.FloatTensor(rp_size[1], 1)
    rpe_split = rp_embeddings:split(batch_size)
    rps_split = rp_scores:split(batch_size)
    rp_trans_boxes = torch.FloatTensor(rp_size)
    rpt_split = rp_trans_boxes:split(batch_size)

    for iv,v in ipairs(region_proposals:split(batch_size)) do
      model.nets.localization_layer.nets.roi_pooling:setImageSize(im_size[3], im_size[4])
      roi_features = model.nets.localization_layer.nets.roi_pooling:forward{feature_maps[1], v}
      roi_features = model.nets.recog_base:forward(roi_features)
      rpe = model.nets.embedding_net:forward(roi_features)  
      rps = model.nets.objectness_branch:forward(roi_features)
      rptrans = model.nets.box_reg_branch:forward(roi_features)
      rpt = apply:forward({v, rptrans})

      rpe_split[iv]:copy(rpe:float())
      rps_split[iv]:copy(rps:float())
      rpt_split[iv]:copy(rpt:float())
    end
    
    bounds = {
      x_min=1, y_min=1,
      x_max=im_size[4], --image_width,
      y_max=im_size[3], --image_height
    }
    rp_trans_boxes, valid = box_utils.clip_boxes(rp_trans_boxes, bounds, 'xcycwh')

    rp_trans_boxes =  box_utils.xcycwh_to_x1y1x2y2(rp_trans_boxes)

    region_proposals = box_utils.xcycwh_to_x1y1x2y2(region_proposals:float())
    table.insert(all_region_proposals, region_proposals)
    table.insert(all_rp_scores, rp_scores)
    table.insert(all_rp_embeddings, rp_embeddings)

    for i = j, (j + boxes:size(1) - 1) do
      btoi[i] = counter
    end
    j = j + boxes:size(1)

    for i = k, (k + rp_size[1] - 1) do
      rptoi[i] = counter
    end
    k = k + rp_size[1]

    model:clearState()
    
    -- Print a message to the console
    local msg = 'Processed image (%d / %d) of split %d, detected %d regions'
    local num_images = info.split_bounds[2]
    local num_boxes = boxes:size(1)
    print(string.format(msg, counter, num_images, split, num_boxes))
    if counter >= num_images then break end
  end

  net = nn.JoinTable(1)

  -- Avoiding deep copies, which is otherwise needed
  l = net:forward(all_logprobs)
  h5_file:write('/logprobs_fold' .. fold, l)
  e = net:forward(all_embeddings)
  h5_file:write('/embeddings_fold' .. fold, e)
  b = net:forward(all_boxes)
  h5_file:write('/boxes_fold' .. fold, b)
  gte = net:forward(all_gt_embeddings)
  h5_file:write('/gt_embeddings_fold' .. fold, gte)
  gts = net:forward(all_gt_scores)
  h5_file:write('/gt_scores_fold' .. fold, gts)
  rps = net:forward(all_rp_scores)
  h5_file:write('/rp_scores_fold' .. fold, rps)
  rpe = net:forward(all_rp_embeddings)
  h5_file:write('/rp_embeddings_fold' .. fold, rpe)
  rp = net:forward(all_region_proposals)
  h5_file:write('/region_proposals_fold' .. fold, rp)
  gtb = net:forward(all_gt_boxes)
  h5_file:write('/gt_boxes_fold' .. fold, gtb)
  btoi = torch.FloatTensor(btoi)
  h5_file:write('/box_to_images_fold' .. fold, btoi)
  rptoi = torch.FloatTensor(rptoi)
  h5_file:write('/rp_to_images_fold' .. fold, rptoi)
end

h5_file:close()
print("Finished writing to " .. h5_out)