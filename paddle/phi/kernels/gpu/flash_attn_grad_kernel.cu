// Copyright (c) 2023 PaddlePaddle Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "paddle/phi/kernels/flash_attn_grad_kernel.h"
#include <cstddef>
#include "glog/logging.h"  // For VLOG()
#include "paddle/common/flags.h"
#include "paddle/phi/backends/gpu/gpu_context.h"
#include "paddle/phi/common/bfloat16.h"
#include "paddle/phi/core/dense_tensor.h"
#include "paddle/phi/core/kernel_registry.h"
#include "paddle/phi/core/tensor_utils.h"
#include "paddle/phi/kernels/funcs/elementwise_base.h"
#include "paddle/phi/kernels/gpu/flash_attn_utils.h"
#include "paddle/phi/kernels/reduce_sum_kernel.h"

COMMON_DECLARE_bool(cudnn_deterministic);

namespace phi {

int get_num_split() {
  // 0 for an internal heuristic, which is optimal
  return FLAGS_cudnn_deterministic ? 1 : 0;
}
bool isContiguous(const DenseTensor& t) {
  auto rank = t.dims().size();
  auto s = t.strides()[rank - 1];
  if (s != 1) return false;
  for (auto i = rank - 1; i > 0;) {
    s *= t.dims()[i];
    i--;
    if (t.strides()[i] != s) {
      return false;
    }
  }
  return true;
}
template <typename T>
__global__ void SumStridedKV(T* src,
                             T* dst,
                             size_t sRowDim1,
                             size_t sRowDim2,
                             size_t sRowDim3,
                             size_t sColDim,
                             size_t sRowStride1,
                             size_t sRowStride2,
                             size_t sRowStride3,
                             size_t sColStride,
                             size_t dRowStride1,
                             size_t dRowStride2,
                             size_t dRowStride3) {
  for (size_t row1 = blockIdx.x; row1 < sRowDim1; row1 += gridDim.x)
    for (size_t row2 = 0; row2 < sRowDim2; row2++)
      for (size_t row3 = threadIdx.x; row3 < sRowDim3; row3 += blockDim.x) {
        T v{0};
        for (size_t col = 0; col < sColDim; col++) {
          v += src[row1 * sRowStride1 + row2 * sRowStride2 +
                   row3 * sRowStride3 + col * sColStride];
        }
        dst[row1 * dRowStride1 + row2 * dRowStride2 + row3 * dRowStride3] = v;
      }
}

template <typename T, typename Context>
void kvReduceForGQA(const Context& ctx,
                    const DenseTensor& dk_tmp,
                    DenseTensor& dk) {
  const size_t reduceDimSize = dk_tmp.dims()[2];
  const size_t blockNum = std::min((dk_tmp.dims()[0] + 127) / 128, 1024l);
  SumStridedKV<T><<<blockNum, 128, 0, ctx.stream()>>>((T*)dk_tmp.data(),
                                                      (T*)dk.data(),
                                                      dk_tmp.dims()[0],
                                                      dk_tmp.dims()[1],
                                                      dk_tmp.dims()[3],
                                                      dk_tmp.dims()[2],
                                                      dk_tmp.strides()[0],
                                                      dk_tmp.strides()[1],
                                                      dk_tmp.strides()[3],
                                                      dk_tmp.strides()[2],
                                                      dk.strides()[0],
                                                      dk.strides()[1],
                                                      dk.strides()[2]);
}
template <typename T, typename Context>
void kvReduceBatchedForGQA(const Context& ctx,
                           const DenseTensor& dk_tmp,
                           DenseTensor& dk) {
  const size_t reduceDimSize = dk_tmp.dims()[3];
  const size_t blockNum = std::min((dk_tmp.dims()[0] + 127) / 128, 1024l);
  // here implicitly flat [batch,seqlen], and require batch dim to be contiguous
  SumStridedKV<T>
      <<<blockNum, 128, 0, ctx.stream()>>>((T*)dk_tmp.data(),
                                           (T*)dk.data(),
                                           dk_tmp.dims()[0] * dk_tmp.dims()[1],
                                           dk_tmp.dims()[2],
                                           dk_tmp.dims()[4],
                                           dk_tmp.dims()[3],
                                           dk_tmp.strides()[1],
                                           dk_tmp.strides()[2],
                                           dk_tmp.strides()[4],
                                           dk_tmp.strides()[3],
                                           dk.strides()[1],
                                           dk.strides()[2],
                                           dk.strides()[3]);
}
template <typename T, typename Context>
void FlashAttnUnpaddedGradBaseKernel(
    const Context& ctx,
    const DenseTensor& q,
    const DenseTensor& k,
    const DenseTensor& v,
    const DenseTensor& cu_seqlens_q,
    const DenseTensor& cu_seqlens_k,
    const DenseTensor& out,
    const DenseTensor& softmax_lse,
    const DenseTensor& seed_offset,
    const paddle::optional<DenseTensor>& attn_mask,
    const DenseTensor& dout,
    int64_t max_seqlen_q,
    int64_t max_seqlen_k,
    float scale,
    float dropout,
    bool causal,
    DenseTensor* dq,
    DenseTensor* dk,
    DenseTensor* dv,
    bool varlen_padded) {
#ifdef PADDLE_WITH_FLASHATTN
  // q,k,v [total_*, num_heads, head_dim]
  auto dims = q.dims();

  const int64_t batch_size = cu_seqlens_q.numel() - 1;
  const int64_t num_heads = dims[1];
  const int64_t head_size_og = dout.dims()[2];
  const int64_t head_size = dims[2];
  const int64_t total_k = k.dims()[0];
  const int64_t num_heads_k = k.dims()[1];

  bool is_mha = (num_heads == num_heads_k);

  DenseTensor* kdq = dq;
  DenseTensor dq_tmp;
  if (!dq) {
    dq_tmp.Resize(dims);
    ctx.template Alloc<T>(&dq_tmp);
    kdq = &dq_tmp;
  }

  std::initializer_list<int64_t> dk_dv_shape = {
      total_k, num_heads_k, num_heads / num_heads_k, head_size};

  DenseTensor *kdk = dk, *kdv = dv;
  DenseTensor dk_tmp;
  if (!dk || !is_mha) {
    dk_tmp.Resize(dk_dv_shape);
    ctx.template Alloc<T>(&dk_tmp);
    kdk = &dk_tmp;
  }

  DenseTensor dv_tmp;
  if (!dv || !is_mha) {
    dv_tmp.Resize(dk_dv_shape);
    ctx.template Alloc<T>(&dv_tmp);
    kdv = &dv_tmp;
  }

  const cudaStream_t stream = ctx.stream();

  int num_splits = get_num_split();

  // TODO(umiswing): add shape check
  PADDLE_ENFORCE_EQ(
      head_size_og,
      head_size,
      phi::errors::InvalidArgument(
          "flash_attn_bwd receive input with head_size_og == head_size"));

  FlashAttnBwdParamsV2 params =
      FlashAttnBwdParamsV2(ctx,
                           batch_size,
                           max_seqlen_q,
                           max_seqlen_k,
                           num_heads,
                           num_heads_k,
                           head_size,
                           dropout,
                           scale,
                           causal,
                           q.dtype(),
                           attn_mask,
                           seed_offset.data<int64_t>());

  VLOG(10) << "FlashAttn bwd seed: " << params.seed
           << ", offset: " << params.offset;

  bool succ = phi::dynload::flash_attn_varlen_bwd(
      dout.data(),
      q.data(),
      k.data(),
      v.data(),
      out.data(),
      params.softmax_d.data(),
      softmax_lse.data(),
      cu_seqlens_q.data<int32_t>(),
      cu_seqlens_k.data<int32_t>(),
      params.rng_state.data(),
      kdq->data(),
      kdk->data(),
      kdv->data(),
      params.dq_accum.data(),
      params.batch_size,
      params.max_seqlen_q,
      params.max_seqlen_k,
      params.seqlen_q_rounded,
      params.seqlen_k_rounded,
      params.num_heads,
      params.num_heads_k,
      params.head_size,
      params.head_size_rounded,
      params.dropout,
      params.softmax_scale,
      1.0f / params.softmax_scale,
      params.causal,
      params.is_bf16,
      num_splits,
      stream,
      params.seed,
      params.offset,
      params.attn_mask_tensor ? params.attn_mask_tensor->data() : nullptr,
      params.attn_mask_tensor ? params.mask_dims.data() : nullptr,
      q.strides()[0],
      k.strides()[0],
      v.strides()[0],
      q.strides()[1],
      k.strides()[1],
      v.strides()[1],
      out.strides()[0],
      out.strides()[1],
      max_seqlen_q * q.strides()[0],
      max_seqlen_k * k.strides()[0],
      max_seqlen_k * v.strides()[0],
      max_seqlen_q * out.strides()[0],
      kdq->strides()[0],
      kdk->strides()[0],
      kdv->strides()[0],
      kdq->strides()[1],
      kdk->strides()[kdk->strides().size() - 2],
      kdv->strides()[kdv->strides().size() - 2],
      dout.strides()[0],
      dout.strides()[1],
      max_seqlen_q * kdq->strides()[0],
      max_seqlen_k * kdk->strides()[0],
      max_seqlen_k * kdv->strides()[0],
      max_seqlen_q * dout.strides()[0],
      varlen_padded);
  CheckFlashAttnStatus(succ);
  if (!is_mha) {
    if (dk) {
      if (isContiguous(*dk))
        phi::SumKernel<T, Context>(ctx, dk_tmp, {2}, dk->type(), false, dk);
      else
        kvReduceForGQA<T, Context>(ctx, dk_tmp, *dk);
    }
    if (dv) {
      if (isContiguous(*dv))
        phi::SumKernel<T, Context>(ctx, dv_tmp, {2}, dv->type(), false, dv);
      else
        kvReduceForGQA<T, Context>(ctx, dv_tmp, *dv);
    }
  }
#else
  RaiseNotSupportedError();
#endif
}

template <typename T, typename Context>
void FlashAttnUnpaddedGradKernel(const Context& ctx,
                                 const DenseTensor& q,
                                 const DenseTensor& k,
                                 const DenseTensor& v,
                                 const DenseTensor& cu_seqlens_q,
                                 const DenseTensor& cu_seqlens_k,
                                 const DenseTensor& out,
                                 const DenseTensor& softmax_lse,
                                 const DenseTensor& seed_offset,
                                 const paddle::optional<DenseTensor>& attn_mask,
                                 const DenseTensor& dout,
                                 int64_t max_seqlen_q,
                                 int64_t max_seqlen_k,
                                 float scale,
                                 float dropout,
                                 bool causal,
                                 DenseTensor* dq,
                                 DenseTensor* dk,
                                 DenseTensor* dv) {
#ifdef PADDLE_WITH_FLASHATTN
  if (dq) {
    ctx.template Alloc<T>(dq);
  }
  if (dk) {
    ctx.template Alloc<T>(dk);
  }
  if (dv) {
    ctx.template Alloc<T>(dv);
  }
  FlashAttnUnpaddedGradBaseKernel<T>(ctx,
                                     q,
                                     k,
                                     v,
                                     cu_seqlens_q,
                                     cu_seqlens_k,
                                     out,
                                     softmax_lse,
                                     seed_offset,
                                     attn_mask,
                                     dout,
                                     max_seqlen_q,
                                     max_seqlen_k,
                                     scale,
                                     dropout,
                                     causal,
                                     dq,
                                     dk,
                                     dv,
                                     false /*varlen_padded*/);
#else
  RaiseNotSupportedError();
#endif
}

static void sliceFlattenView(const DenseTensor& in,
                             DenseTensor& out,
                             int axis,
                             int64_t offset,
                             int64_t sliceLength) {
  PADDLE_ENFORCE_LT(
      axis,
      in.dims().size(),
      phi::errors::InvalidArgument("sliceView receive axis out of bound"));
  std::array<int64_t, DDim::kMaxRank> dimArr;
  std::array<int64_t, DDim::kMaxRank> strideArr;
  auto id = dimArr.begin(), is = strideArr.begin();
  for (int i = 0; i < in.dims().size(); i++) {
    if (i == axis) continue;
    if (i == axis + 1)
      *id = in.dims()[i] * sliceLength;
    else
      *id = in.dims()[i];
    *is = in.strides()[i];
    id++;
    is++;
  }
  out = DenseTensor{
      in.Holder(),
      DenseTensorMeta{in.dtype(),
                      DDim{dimArr.data(), in.dims().size() - 1},
                      DDim(strideArr.data(), in.dims().size() - 1)}};
  out.set_offset(in.offset() +
                 offset * in.strides()[axis] * SizeOf(out.dtype()));
}
template <typename OutT>
struct ZeroFunctor {
  __device__ __forceinline__ OutT operator()() const {
    return static_cast<OutT>(0);
  }
};
template <typename T, typename Context>
void FlashAttnVarlenQKVPackedGradKernel(
    const Context& ctx,
    const DenseTensor& qkv,
    const DenseTensor& cu_seqlens_q,
    const DenseTensor& cu_seqlens_k,
    const DenseTensor& out,
    const DenseTensor& softmax_lse,
    const DenseTensor& seed_offset,
    const paddle::optional<DenseTensor>& attn_mask,
    const DenseTensor& dout,
    int64_t max_seqlen_q,
    int64_t max_seqlen_k,
    float scale,
    float dropout,
    bool causal,
    bool varlen_padded,
    DenseTensor* dqkv) {
#ifdef PADDLE_WITH_FLASHATTN
  // q,k,v [total_*, num_heads, head_dim]
  const auto head_groupnum = qkv.dims()[1];  // nheads/nheads_k + 1 + 1
  DenseTensor q, k, v;
  sliceFlattenView(qkv, q, 1, 0, head_groupnum - 2);
  sliceFlattenView(qkv, k, 1, head_groupnum - 2, 1);
  sliceFlattenView(qkv, v, 1, head_groupnum - 1, 1);
  // DenseTensor dqkv_tmp;
  if (!dqkv) {
    return;
    // dqkv is the only output. No need to compute if no dqkv
    // dqkv_tmp.Resize(qkv.dims());
    // dqkv = &dqkv_tmp;
  }
  ctx.template Alloc<T>(dqkv);
  {
    std::vector<const DenseTensor*> inputs{};
    std::vector<DenseTensor*> outputs{dqkv};
    phi::funcs::ElementwiseKernel<T>(ctx, inputs, &outputs, ZeroFunctor<T>());
  }
  DenseTensor dq, dk, dv;
  sliceFlattenView(*dqkv, dq, 1, 0, head_groupnum - 2);
  sliceFlattenView(*dqkv, dk, 1, head_groupnum - 2, 1);
  sliceFlattenView(*dqkv, dv, 1, head_groupnum - 1, 1);
  FlashAttnUnpaddedGradBaseKernel<T>(ctx,
                                     q,
                                     k,
                                     v,
                                     cu_seqlens_q,
                                     cu_seqlens_k,
                                     out,
                                     softmax_lse,
                                     seed_offset,
                                     attn_mask,
                                     dout,
                                     max_seqlen_q,
                                     max_seqlen_k,
                                     scale,
                                     dropout,
                                     causal,
                                     &dq,
                                     &dk,
                                     &dv,
                                     varlen_padded);
#else
  RaiseNotSupportedError();
#endif
}
template <typename T, typename Context>
void FlashAttnGradBaseKernel(
    const Context& ctx,
    const DenseTensor& q,
    const DenseTensor& k,
    const DenseTensor& v,
    const DenseTensor& out,
    const DenseTensor& softmax_lse,
    const DenseTensor& seed_offset,
    const paddle::optional<DenseTensor>& attn_mask,
    const paddle::optional<DenseTensor>& attn_mask_start_row_indices,
    const DenseTensor& dout,
    float dropout,
    bool causal,
    int attn_mask_start_row,
    DenseTensor* dq,
    DenseTensor* dk,
    DenseTensor* dv) {
#ifdef PADDLE_WITH_FLASHATTN
  // q, k, v [batch_size, seq_len, num_heads, head_dim]
  const auto& dims = q.dims();

  const int64_t batch_size = dims[0];
  const int64_t seqlen_q = dims[1];
  const int64_t num_heads = dims[2];
  const int64_t head_size_og = dout.dims()[3];
  const int64_t head_size = dims[3];
  const int64_t seqlen_k = k.dims()[1];
  const int64_t num_heads_k = k.dims()[2];

  bool is_mha = (num_heads == num_heads_k);

  std::initializer_list<int64_t> dk_dv_shape = {
      batch_size, seqlen_k, num_heads_k, num_heads / num_heads_k, head_size};
  DenseTensor* kdq = dq;
  DenseTensor dq_tmp;
  if (!dq) {
    dq_tmp.Resize(dims);
    ctx.template Alloc<T>(&dq_tmp);
    kdq = &dq_tmp;
  }

  DenseTensor *kdk = dk, *kdv = dv;
  DenseTensor dk_tmp;
  if (!dk || !is_mha) {
    dk_tmp.Resize(dk_dv_shape);
    ctx.template Alloc<T>(&dk_tmp);
    kdk = &dk_tmp;
  }

  DenseTensor dv_tmp;
  if (!dv || !is_mha) {
    dv_tmp.Resize(dk_dv_shape);
    ctx.template Alloc<T>(&dv_tmp);
    kdv = &dv_tmp;
  }

  const cudaStream_t stream = ctx.stream();

  // TODO(umiswing): add shape check
  PADDLE_ENFORCE_EQ(
      head_size_og,
      head_size,
      phi::errors::InvalidArgument(
          "flash_attn_bwd receive input with head_size_og == head_size"));

  const float softmax_scale = 1.0f / std::sqrt(head_size);
  const float softmax_unscale = std::sqrt(head_size);

  FlashAttnBwdParamsV2 params =
      FlashAttnBwdParamsV2(ctx,
                           batch_size,
                           seqlen_q,
                           seqlen_k,
                           num_heads,
                           num_heads_k,
                           head_size,
                           dropout,
                           softmax_scale,
                           causal,
                           attn_mask_start_row,
                           q.dtype(),
                           attn_mask,
                           attn_mask_start_row_indices,
                           seed_offset.data<int64_t>());

  VLOG(10) << "[FlashAttn Forward] q.shape=[" << q.dims() << "], k.shape=["
           << k.dims() << "], v.shape=[" << v.dims() << "]";
  VLOG(10) << "[FlashAttn Forward] dropout=" << dropout
           << ", seed=" << params.seed << ", offset=" << params.offset;
  VLOG(10) << "[FlashAttn Forward] softmax_scale=" << softmax_scale
           << ", softmax_unscale=" << softmax_unscale;
  if (attn_mask.get_ptr()) {
    VLOG(10) << "[FlashAttn Backward] attn_mask.shape=["
             << (attn_mask.get_ptr())->dims() << "]";
  }

  int num_splits = get_num_split();

  bool succ = phi::dynload::flash_attn_bwd(
      dout.data(),
      q.data(),
      k.data(),
      v.data(),
      out.data(),
      params.softmax_d.data(),
      softmax_lse.data(),
      params.rng_state.data(),
      kdq->data(),
      kdk->data(),
      kdv->data(),
      params.dq_accum.data(),
      params.batch_size,
      params.max_seqlen_q,
      params.max_seqlen_k,
      params.seqlen_q_rounded,
      params.seqlen_k_rounded,
      params.num_heads,
      params.num_heads_k,
      params.head_size,
      params.head_size_rounded,
      params.dropout,
      params.softmax_scale,
      softmax_unscale,
      params.causal,
      params.is_bf16,
      num_splits,
      stream,
      params.seed,
      params.offset,
      params.attn_mask_tensor ? params.attn_mask_tensor->data() : nullptr,
      params.attn_mask_tensor ? params.mask_dims.data() : nullptr,
      params.attn_mask_start_row_indices_tensor
          ? params.attn_mask_start_row_indices_tensor->data()
          : nullptr,
      params.attn_mask_start_row_indices_tensor
          ? params.attn_mask_start_row_indices_dims.data()
          : nullptr,
      params.attn_mask_start_row,
      q.strides()[1],
      k.strides()[1],
      v.strides()[1],
      q.strides()[2],
      k.strides()[2],
      v.strides()[2],
      out.strides()[1],
      out.strides()[2],
      q.strides()[0],
      k.strides()[0],
      v.strides()[0],
      out.strides()[0],
      kdq->strides()[1],
      kdk->strides()[1],
      kdv->strides()[1],
      kdq->strides()[2],
      kdk->strides()[kdk->strides().size() - 2],
      kdv->strides()[kdv->strides().size() - 2],
      dout.strides()[1],
      dout.strides()[2],
      kdq->strides()[0],
      kdk->strides()[0],
      kdv->strides()[0],
      dout.strides()[0]);
  CheckFlashAttnStatus(succ);
  if (!is_mha) {
    if (dk) {
      if (isContiguous(*dk))
        phi::SumKernel<T, Context>(ctx, dk_tmp, {3}, dk->type(), false, dk);
      else
        kvReduceBatchedForGQA<T, Context>(ctx, dk_tmp, *dk);
    }

    if (dv) {
      if (isContiguous(*dv))
        phi::SumKernel<T, Context>(ctx, dv_tmp, {3}, dv->type(), false, dv);
      else
        kvReduceBatchedForGQA<T, Context>(ctx, dv_tmp, *dv);
    }
  }
#else
  RaiseNotSupportedError();
#endif
}

template <typename T, typename Context>
void FlashAttnGradKernel(const Context& ctx,
                         const DenseTensor& q,
                         const DenseTensor& k,
                         const DenseTensor& v,
                         const DenseTensor& out,
                         const DenseTensor& softmax_lse,
                         const DenseTensor& seed_offset,
                         const paddle::optional<DenseTensor>& attn_mask,
                         const DenseTensor& dout,
                         float dropout,
                         bool causal,
                         DenseTensor* dq,
                         DenseTensor* dk,
                         DenseTensor* dv) {
  FlashAttnGradBaseKernel<T, Context>(ctx,
                                      q,
                                      k,
                                      v,
                                      out,
                                      softmax_lse,
                                      seed_offset,
                                      attn_mask,
                                      paddle::none,
                                      dout,
                                      dropout,
                                      causal,
                                      0,
                                      dq,
                                      dk,
                                      dv);
}

template <typename T, typename Context>
void FlashAttnQKVPackedGradKernel(
    const Context& ctx,
    const DenseTensor& qkv,
    const DenseTensor& out,
    const DenseTensor& softmax_lse,
    const DenseTensor& seed_offset,
    const paddle::optional<DenseTensor>& attn_mask,
    const DenseTensor& dout,
    float dropout,
    bool causal,
    DenseTensor* dqkv) {
#ifdef PADDLE_WITH_FLASHATTN
  // qkv [batchsize, seqlen, nheads/nheads_k+2, nheads_k, head_dim]
  const auto head_groupnum = qkv.dims()[2];  // nheads/nheads_k + 1 + 1
  DenseTensor q, k, v;
  sliceFlattenView(qkv, q, 2, 0, head_groupnum - 2);
  sliceFlattenView(qkv, k, 2, head_groupnum - 2, 1);
  sliceFlattenView(qkv, v, 2, head_groupnum - 1, 1);
  // DenseTensor dqkv_tmp;
  if (!dqkv) {
    return;
    // dqkv is the only output. No need to compute if no dqkv
    // dqkv_tmp.Resize(qkv.dims());
    // dqkv = &dqkv_tmp;
  }
  ctx.template Alloc<T>(dqkv);
  DenseTensor dq, dk, dv;
  sliceFlattenView(*dqkv, dq, 2, 0, head_groupnum - 2);
  sliceFlattenView(*dqkv, dk, 2, head_groupnum - 2, 1);
  sliceFlattenView(*dqkv, dv, 2, head_groupnum - 1, 1);
  FlashAttnGradBaseKernel<T, Context>(ctx,
                                      q,
                                      k,
                                      v,
                                      out,
                                      softmax_lse,
                                      seed_offset,
                                      attn_mask,
                                      paddle::none,
                                      dout,
                                      dropout,
                                      causal,
                                      0,
                                      &dq,
                                      &dk,
                                      &dv);
#else
  RaiseNotSupportedError();
#endif
}

template <typename T, typename Context>
void FlashAttnWithSparseGradKernel(
    const Context& ctx,
    const DenseTensor& q,
    const DenseTensor& k,
    const DenseTensor& v,
    const DenseTensor& attn_mask_start_row_indices,
    const DenseTensor& out,
    const DenseTensor& softmax_lse,
    const DenseTensor& seed_offset,
    const DenseTensor& dout,
    float dropout,
    bool causal,
    int attn_mask_start_row,
    DenseTensor* dq,
    DenseTensor* dk,
    DenseTensor* dv) {
  FlashAttnGradBaseKernel<T, Context>(ctx,
                                      q,
                                      k,
                                      v,
                                      out,
                                      softmax_lse,
                                      seed_offset,
                                      paddle::none,
                                      attn_mask_start_row_indices,
                                      dout,
                                      dropout,
                                      causal,
                                      attn_mask_start_row,
                                      dq,
                                      dk,
                                      dv);
}
}  // namespace phi

PD_REGISTER_KERNEL(flash_attn_unpadded_grad,
                   GPU,
                   ALL_LAYOUT,
                   phi::FlashAttnUnpaddedGradKernel,
                   phi::dtype::float16,
                   phi::dtype::bfloat16) {
  kernel->InputAt(7).SetBackend(phi::Backend::ALL_BACKEND);  // seed_offset
}

PD_REGISTER_KERNEL(flash_attn_varlen_qkvpacked_grad,
                   GPU,
                   ALL_LAYOUT,
                   phi::FlashAttnVarlenQKVPackedGradKernel,
                   phi::dtype::float16,
                   phi::dtype::bfloat16) {
  kernel->InputAt(5).SetBackend(phi::Backend::ALL_BACKEND);  // seed_offset
}

PD_REGISTER_KERNEL(flash_attn_grad,
                   GPU,
                   ALL_LAYOUT,
                   phi::FlashAttnGradKernel,
                   phi::dtype::float16,
                   phi::dtype::bfloat16) {
  kernel->InputAt(5).SetBackend(phi::Backend::ALL_BACKEND);  // seed_offset
}

PD_REGISTER_KERNEL(flash_attn_qkvpacked_grad,
                   GPU,
                   ALL_LAYOUT,
                   phi::FlashAttnQKVPackedGradKernel,
                   phi::dtype::float16,
                   phi::dtype::bfloat16) {
  kernel->InputAt(3).SetBackend(phi::Backend::ALL_BACKEND);  // seed_offset
}

PD_REGISTER_KERNEL(flash_attn_with_sparse_mask_grad,
                   GPU,
                   ALL_LAYOUT,
                   phi::FlashAttnWithSparseGradKernel,
                   phi::dtype::float16,
                   phi::dtype::bfloat16) {
  kernel->InputAt(6).SetBackend(phi::Backend::ALL_BACKEND);  // seed_offset
}