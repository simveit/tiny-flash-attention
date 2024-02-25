#include <cassert>
#include <cmath>
#include <cuda_runtime.h>
#include <stdio.h>
#include <cutlass/numeric_conversion.h>
#include <cutlass/numeric_types.h>

#include "flash.h"
#include "kernel_traits.h"
#include "utils.h"

// data type to test
using FP = float;
using FPC = cute::half_t;
// Out type
using FPC_O = float;
// using FPC = double;
// BLOCK_M(Br, Brow), BLOCK_N(Bc, Bcol) can be determined at compile time
// just like offical implementation which use a template kernel to do that
// Block row size
// TODO: 测试这里多种shape
const int Bm = 8 * 8;
// Block column size
const int Bn = 8 * 2;
// seqlen
// TODO: correctness bug case: bug when seqlen < dim?
// const int Input_seq = 8 * 4 * 2;
// const int Dim = 4 * 8 * 4;
const int Input_seq = 8 * 4 * 4;
// dim
const int Dim = 4 * 8 * 2;
// TODO: warp!=1情况有bug
const int Warps = 1;

// debug only
int TX = 0;
int TY = 0;

// TODO: test trait
using Test_Traits = Flash_fwd_kernel_traits<Dim, Bm, Bn, Warps, false, false, FPC>;


// Shared Storage with Aligned addresses.
template <class ElementType, class SmemLayoutQ, class SmemLayoutK, class SmemLayoutV>
struct SharedStorage {
  // TODO: Aligned的话smem的计算是否有问题
  cute::array_aligned<ElementType, cute::cosize_v<SmemLayoutQ>> smem_q;
  cute::array_aligned<ElementType, cute::cosize_v<SmemLayoutK>> smem_k;
  cute::array_aligned<ElementType, cute::cosize_v<SmemLayoutV>> smem_v;
};


#define CUDA_CHECK(condition)                                                  \
  do {                                                                         \
    cudaError_t error = condition;                                             \
    if (error != cudaSuccess) {                                                \
      printf("CUDA_CHECK error in line %d of file %s \
              : %s \n",                                                        \
             __LINE__, __FILE__, cudaGetErrorString(cudaGetLastError()));      \
      exit(EXIT_FAILURE);                                                      \
    }                                                                          \
  } while (0)

// #define DEBUG

#ifdef DEBUG
#define DEBUG_BLOCK(expr)                                                      \
  do {                                                                         \
    expr                                                                       \
  } while (0)
#else
#define DEBUG_BLOCK(...)                                                       \
  do {                                                                         \
  } while (0)
#endif

// TODO: 待功能差不多后再使用torch
void set_params_fprop(Flash_fwd_params &params,
                      // sizes
                      const size_t bs, const size_t head, const size_t seqlen,
                      const size_t dim,

                      const size_t bs_stride, const size_t head_stride,
                      const size_t seqlen_stride, const size_t dim_stride,

                      // // device pointers
                      // const torch::Tensor q,
                      // const torch::Tensor k,
                      // const torch::Tensor v,
                      // torch::Tensor out,

                      void *q, void *k, void *v, void *out,

                      float softmax_scale) {

  memset(&params, 0, sizeof(params));

  params.bs = bs;
  params.head = head;
  params.seqlen = seqlen;
  params.dim = dim;

  params.bs_stride = bs_stride;
  params.head_stride = head_stride;
  params.seqlen_stride = seqlen_stride;
  params.dim_stride = dim_stride;

  params.softmax_scale = softmax_scale;

  // TODO: get ptr
  params.q_ptr = q;
  params.k_ptr = k;
  params.v_ptr = v;
  params.out_ptr = out;
}

__global__ void naive_nrow_gemm(FP *A, FP *B, FP *C, FP a, FP b,
                                int M, int N, int K, int mBlock);
__global__ void row_softmax(FP *input, FP *output, int n);
__global__ void naive_pv(FP *P, FP *V, FP *O, int M, int N,
                         int mBlock);

template<typename T>
void print_host_matrix(T *matrix, int m, int n);
template<typename T>
void print_device_matrix(T *matrix, int m, int n);
template<typename T, typename U>
bool all_close(T *A, U *B, int m, int n);

namespace flash {

using namespace cute;

/// TODO: review

// NOTE: A矩阵已经在寄存器中的gemm封装
template<typename Tensor0, typename Tensor1, typename Tensor2, typename Tensor3,
         typename TiledMma, typename TiledCopy, typename ThrCopy>
inline __device__ void gemm_A_in_regs(Tensor0 &acc, Tensor1 &tCrA, Tensor2 &tCrB, Tensor3 const& tCsB,
                                      TiledMma tiled_mma, TiledCopy smem_tiled_copy_B,
                                      ThrCopy smem_thr_copy_B) {
    // NOTE: 符合M N K描述: A[M, K] @ B[N, K] = C[M, N]
    CUTE_STATIC_ASSERT_V(size<1>(tCrA) == size<1>(acc));                     // MMA_M
    CUTE_STATIC_ASSERT_V(size<1>(tCrB) == size<2>(acc));                     // MMA_N
    CUTE_STATIC_ASSERT_V(size<2>(tCrA) == size<2>(tCrB));                     // MMA_K
    // NOTE: retile 成拷贝需要的大小
    Tensor tCrB_copy_view = smem_thr_copy_B.retile_D(tCrB);
    CUTE_STATIC_ASSERT_V(size<1>(tCsB) == size<1>(tCrB_copy_view));            // N
    cute::copy(smem_tiled_copy_B, tCsB(_, _, _0{}), tCrB_copy_view(_, _, _0{}));
    #pragma unroll
    for (int i = 0; i < size<2>(tCrA); ++i) {
        if (i < size<2>(tCrA) - 1) {
            cute::copy(smem_tiled_copy_B, tCsB(_, _, i + 1), tCrB_copy_view(_, _, i + 1));
        }
        cute::gemm(tiled_mma, tCrA(_, _, i), tCrB(_, _, i), acc);
    }
}

template<typename Tensor0, typename Tensor1,
         typename Tensor2, typename Tensor3, typename Tensor4,
         typename TiledMma, typename TiledCopyA, typename TiledCopyB,
         typename ThrCopyA, typename ThrCopyB>
inline __device__ void gemm_smem(Tensor0 &acc, Tensor1 &tCrA, Tensor2 &tCrB, Tensor3 const& tCsA,
                            Tensor4 const& tCsB, TiledMma tiled_mma,
                            TiledCopyA smem_tiled_copy_A, TiledCopyB smem_tiled_copy_B,
                            ThrCopyA smem_thr_copy_A, ThrCopyB smem_thr_copy_B) {
    CUTE_STATIC_ASSERT_V(size<1>(tCrA) == size<1>(acc));                     // MMA_M
    CUTE_STATIC_ASSERT_V(size<1>(tCrB) == size<2>(acc));                     // MMA_N
    CUTE_STATIC_ASSERT_V(size<2>(tCrA) == size<2>(tCrB));                     // MMA_K
    Tensor tCrA_copy_view = smem_thr_copy_A.retile_D(tCrA);
    CUTE_STATIC_ASSERT_V(size<1>(tCsA) == size<1>(tCrA_copy_view));            // M
    Tensor tCrB_copy_view = smem_thr_copy_B.retile_D(tCrB);
    CUTE_STATIC_ASSERT_V(size<1>(tCsB) == size<1>(tCrB_copy_view));            // N
    // NOTE: s -> reg
    cute::copy(smem_tiled_copy_A, tCsA(_, _, _0{}), tCrA_copy_view(_, _, _0{}));
    cute::copy(smem_tiled_copy_B, tCsB(_, _, _0{}), tCrB_copy_view(_, _, _0{}));
    #pragma unroll
    for (int i = 0; i < size<2>(tCrA); ++i) {
        if (i < size<2>(tCrA) - 1) {
            cute::copy(smem_tiled_copy_A, tCsA(_, _, i + 1), tCrA_copy_view(_, _, i + 1));
            cute::copy(smem_tiled_copy_B, tCsB(_, _, i + 1), tCrB_copy_view(_, _, i + 1));
        }
        cute::gemm(tiled_mma, tCrA(_, _, i), tCrB(_, _, i), acc);
    }
}

// Blocks until all but N previous cp.async.commit_group operations have committed.
// This differs from cute::cp_async_wait in that when N = 0 we don't call cp.async.wait_all
// (which is equivalent to commit_group then wait_group 0).
// Instead we just call cp.async.wait_group 0, which is slightly faster.
// https://github.com/NVIDIA/cutlass/blob/master/include/cute/arch/copy_sm80.hpp#L113
template <int N>
CUTE_HOST_DEVICE
void cp_async_wait() {
#if defined(CUTE_ARCH_CP_ASYNC_SM80_ENABLED)
    asm volatile("cp.async.wait_group %0;\n" :: "n"(N));
#endif
}

// copy from S to D with tiled_copy
// TODO: 需要支持causal模式的的跳过拷贝
template <typename TiledCopy, typename Engine0, typename Layout0, typename Engine1, typename Layout1>
inline __device__ void copy(TiledCopy tiled_copy, Tensor<Engine0, Layout0> const &S,
                            Tensor<Engine1, Layout1> &D) {
    CUTE_STATIC_ASSERT_V(rank(S) == Int<3>{});
    CUTE_STATIC_ASSERT_V(rank(D) == Int<3>{});
    CUTE_STATIC_ASSERT_V(size<0>(S) == size<0>(D));                     // MMA
    CUTE_STATIC_ASSERT_V(size<1>(S) == size<1>(D));                     // MMA_M
    CUTE_STATIC_ASSERT_V(size<2>(S) == size<2>(D));                     // MMA_K

    #pragma unroll
    for (int m = 0; m < size<1>(S); ++m) {
        // TODO: 原版处这里identity_MN是用来跳过大块的block的, predicate用于跳过block内的拷贝
        // TODO: 添加predicate逻辑, 用于跳过无用拷贝
        // if (get<0>(identity_MN(0, m, 0)) < max_MN)
        #pragma unroll
        for (int k = 0; k < size<2>(S); ++k) {
          cute::copy(tiled_copy, S(_, m, k), D(_, m, k));
        }
    }
}


// Convert rowcol_layout from (nrow=(2, MMA_M), ncol=(2, MMA_N)) to ((2, 2, 2), MMA_M, MMA_N / 2)
// if using m16n8k16, or to ((2, 2, 1), MMA_M, MMA_N) if using m16n8k8.
template<typename MMA_traits, typename Layout>
inline __device__ auto convert_layout_rowcol_Aregs(Layout rowcol_layout) {
    using X = Underscore;
    static_assert(decltype(size<0, 0>(rowcol_layout))::value == 2);
    static_assert(decltype(size<1, 0>(rowcol_layout))::value == 2);
    constexpr int mma_shape_K = get<2>(typename MMA_traits::Shape_MNK{});
    static_assert(mma_shape_K == 8 || mma_shape_K == 16);
    constexpr int MMA_N_divisor = mma_shape_K == 8 ? 1 : 2;
    auto l = logical_divide(rowcol_layout, Shape<X, Shape<X, Int<MMA_N_divisor>>>{});  // ((2, MMA_M), (2, (2, MMA_N / 2)))
    // TD [2023-08-13]: Same error as above on Cutlass 3.2
    // return make_layout(make_layout(get<1, 0>(l), get<0, 0>(l), get<1, 1, 0>(l)),
    //                    get<0, 1>(l),
    //                    get<1, 1, 1>(l));
    return make_layout(make_layout(get<0>(get<1>(l)), get<0>(get<0>(l)), get<0>(get<1>(get<1>(l)))),
                       get<1>(get<0>(l)),
                       get<1>(get<1>(get<1>(l))));
};


// TODO: not work
template <typename To_type, typename Engine, typename Layout>
inline __device__ auto convert_type(Tensor<Engine, Layout> const &tensor) {
    using From_type = typename Engine::value_type;
    constexpr int numel = decltype(size(tensor))::value;
    cutlass::NumericArrayConverter<To_type, From_type, numel> convert_op;
    // HACK: this requires tensor to be "contiguous"
    auto frag = convert_op(*reinterpret_cast<const cutlass::Array<From_type, numel> *>(tensor.data()));
    return make_tensor(make_rmem_ptr<To_type>(&frag), tensor.layout());
}

// TODO:
// https://github.com/NVIDIA/cutlass/issues/802
// TODO: convert出来后数据是否在寄存器?
template <typename Fragment>
inline __device__ auto convert_type_f32_to_f16(Fragment const &acc_fp32) {
  Tensor acc_fp16 = make_tensor<cute::half_t>(shape(acc_fp32));
  {
    Tensor acc_fp32x2 = recast< float2>(acc_fp32);
    Tensor acc_fp16x2 = recast<__half2>(acc_fp16);
    for (int i = 0; i < size(acc_fp32x2); ++i) { acc_fp16x2(i) = __float22half2_rn(acc_fp32x2(i)); }
  }
  return acc_fp16;
}

// Apply the exp to all the elements.
template <bool Scale_max=true, typename Engine0, typename Layout0, typename Engine1, typename Layout1>
inline __device__ void scale_apply_exp2(Tensor<Engine0, Layout0> &tensor, Tensor<Engine1, Layout1> const &max, const float scale) {
    static_assert(Layout0::rank == 2, "Only support 2D Tensor");
    static_assert(Layout1::rank == 1, "Only support 1D Tensor");
    CUTE_STATIC_ASSERT_V(size<0>(max) == size<0>(tensor));
    #pragma unroll
    for (int mi = 0; mi < size<0>(tensor); ++mi) {
        // If max is -inf, then all elements must have been -inf (possibly due to masking).
        // We don't want (-inf - (-inf)) since that would give NaN.
        // If we don't have float around M_LOG2E the multiplication is done in fp64.
        const float max_scaled = max(mi) == -INFINITY ? 0.f : max(mi) * (Scale_max ? scale : float(M_LOG2E));
        #pragma unroll
        for (int ni = 0; ni < size<1>(tensor); ++ni)  {
            // Instead of computing exp(x - max), we compute exp2(x * log_2(e) -
            // max * log_2(e)) This allows the compiler to use the ffma
            // instruction instead of fadd and fmul separately.
            tensor(mi, ni) = exp2f(tensor(mi, ni) * scale - max_scaled);
        }
    }
}


// Convert acc_layout from (MMA=4, MMA_M, MMA_N) to (nrow=(2, MMA_M), ncol=(2, MMA_N))
template<typename Layout>
inline __device__ auto convert_layout_acc_rowcol(Layout acc_layout) {
    static_assert(decltype(size<0>(acc_layout))::value == 4);
    static_assert(decltype(rank(acc_layout))::value == 3);
    auto l = logical_divide(acc_layout, Shape<_2>{});  // ((2, 2), MMA_M, MMA_N)
    // TD [2023-08-13]: Idk why but get<0, 1>(l) doesn't work for Cutlass 3.2, I'm getting
    // "int_tuple.hpp(74): error: conversion to inaccessible base class"
    // return make_layout(make_layout(get<0, 1>(l), get<1>(l)), make_layout(get<0, 0>(l), get<2>(l)));
    return make_layout(make_layout(get<1>(get<0>(l)), get<1>(l)), make_layout(get<0>(get<0>(l)), get<2>(l)));
};


template<bool zero_init=true, typename Engine0, typename Layout0, typename Engine1, typename Layout1, typename Operator>
__device__ inline void thread_reduce_(Tensor<Engine0, Layout0> const &tensor, Tensor<Engine1, Layout1> &summary, Operator &op) {
    static_assert(Layout0::rank == 2, "Only support 2D Tensor");
    static_assert(Layout1::rank == 1, "Only support 1D Tensor");
    CUTE_STATIC_ASSERT_V(size<0>(summary) == size<0>(tensor));
    #pragma unroll
    for (int mi = 0; mi < size<0>(tensor); mi++) {
        summary(mi) = zero_init ? tensor(mi, 0) : op(summary(mi), tensor(mi, 0));
        #pragma unroll
        for (int ni = 1; ni < size<1>(tensor); ni++) {
            summary(mi) = op(summary(mi), tensor(mi, ni));
        }
    }
}

template<typename Engine0, typename Layout0, typename Engine1, typename Layout1, typename Operator>
__device__ inline void quad_allreduce_(Tensor<Engine0, Layout0> &dst, Tensor<Engine1, Layout1> &src, Operator &op) {
    CUTE_STATIC_ASSERT_V(size(dst) == size(src));
    #pragma unroll
    for (int i = 0; i < size(dst); i++){
        // NOTE: 4表示4个线程
        dst(i) = Allreduce<4>::run(src(i), op);
    }
}

template<bool zero_init=true, typename Engine0, typename Layout0, typename Engine1, typename Layout1, typename Operator>
__device__ inline void reduce_(Tensor<Engine0, Layout0> const& tensor, Tensor<Engine1, Layout1> &summary, Operator &op) {
    // NOTE: 遍历tensor每行, 记录到summary中
    // reduce 当前thread的max
    thread_reduce_<zero_init>(tensor, summary, op);
    // NOTE: 二分法对summary[]进行reduce
    // reduce thread间的max
    quad_allreduce_(summary, summary, op);
}


template<bool zero_init=true, typename Engine0, typename Layout0, typename Engine1, typename Layout1>
__device__ inline void reduce_max(Tensor<Engine0, Layout0> const& tensor, Tensor<Engine1, Layout1> &max){
    MaxOp<float> max_op;
    reduce_<zero_init>(tensor, max, max_op);
}

template<typename Engine0, typename Layout0, typename Engine1, typename Layout1>
__device__ inline void reduce_sum(Tensor<Engine0, Layout0> const& tensor, Tensor<Engine1, Layout1> &sum){
    SumOp<float> sum_op;
    reduce_(tensor, sum, sum_op);
}

/// TODO: 

template<typename Tensor0, typename Tensor1, typename Tensor2>
inline __device__ void softmax_rescale_o2(Tensor0 &scores, Tensor1 &scores_max, Tensor1 &scores_sum,
                                         Tensor2 &acc_o, float softmax_scale_log2) {
    // NOTE: scores来自acc_s: Q@K.T
    // acc_s用来暂存QK和softmax的结果[seqlen, seqlen]
    // acc_o用来存储QK@V的结果[seqlen, dim]
    // TODO: 为什么这里是输出到acc_o而不是acc_s

    // 记录上一次的max
    // TODO: 搞清楚max的维度, (MMA_M)??
    Tensor scores_max_prev = make_fragment_like(scores_max);
    cute::copy(scores_max, scores_max_prev);
    // TODO: reduce的实现学习一下
    // NOTE: 计算新max到scores_max
    flash::template reduce_max</*zero_init=*/false>(scores, scores_max);
    // Reshape acc_o from (MMA=4, MMA_M, MMA_K) to (nrow=(2, MMA_M), ncol=(2, MMA_K))
    // TODO: 为什么要reshape acc_o
    // 因为scores的shape是这样的? 那为什么要reshape scores?
    Tensor acc_o_rowcol = make_tensor(acc_o.data(), flash::convert_layout_acc_rowcol(acc_o.layout()));
    #pragma unroll
    for (int mi = 0; mi < size(scores_max); ++mi) {
        // NOTE: 辅助变量: 当前max
        float scores_max_cur = scores_max(mi);
        // NOTE: 计算旧score的rescale值
        // NOTE: 因为QK(影响max)计算时没有考虑softmax_scale, 所以这里要补上
        float scores_scale = exp2f((scores_max_prev(mi) - scores_max_cur) * softmax_scale_log2);
        // NOTE: rescale旧分母部分
        scores_sum(mi) *= scores_scale;
        // NOTE: 旧分子部分rescale
        // TODO: acc_o_rowcol什么原理?
        #pragma unroll
        for (int ni = 0; ni < size<1>(acc_o_rowcol); ++ni) { acc_o_rowcol(mi, ni) *= scores_scale; }
    }
    // NOTE: 计算新分子部分: scores
    flash::scale_apply_exp2(scores, scores_max, softmax_scale_log2);

    // NOTE: 累加新分母
    Tensor scores_sum_cur = make_fragment_like(scores_sum);
    // NOTE:利用新分子来累加新分母
    flash::reduce_sum(scores, scores_sum_cur);
    // NOTE: 新分母累加到旧分母
    #pragma unroll
    for (int mi = 0; mi < size(scores_sum); ++mi) { scores_sum(mi) += scores_sum_cur(mi); }
};


/**
  @params: scores, the result of  QK
  @params: scores_max, the max of each block of row
  @params: acc_o, the output
  @params: softmax_scale_log2, the softmax_scale
 */
template<typename Tensor0, typename Tensor1, typename Tensor2>
inline __device__ void softmax_rescale_o(Tensor0 &scores, Tensor1 &scores_max, Tensor1 &scores_sum,
                                         Tensor2 &acc_o, float softmax_scale_log2) {
  // for each line of QK(scores)
  // 1. compute new max
  // 2. rescale old max
  // 3. sum new denom
  // 4. rescale old denom
  // 5. add old denom and new denom

  Tensor scores_max_prev = make_fragment_like(scores_max);
  cute::copy(scores_max, scores_max_prev);

  // NOTE: 求max
  // 1. 求当前thread内max
  for (int j  = 0; j < size<1>(scores); j++) {
    float local_max = -INFINITY;
    for (int i = 0; i < size<2>(scores); i++) {
      for (int k = 0; k < size<0>(scores); k++) {
        local_max = max(local_max, scores(k, j, i));
      }
    }
    scores_max(j) = local_max;
  }
  // 2. reduce thread间的max
  MaxOp<float> max_op;
  quad_allreduce_(scores_max, scores_max, max_op);

  for (int mi = 0; mi < size(scores_max); mi++) {
    float scores_max_cur = scores_max(mi);
    // NOTE: 计算旧score的rescale值
    // NOTE: 因为QK(影响max)计算时没有考虑softmax_scale, 所以这里要补上
    float scores_scale = exp2f((scores_max_prev(mi) - scores_max_cur) * softmax_scale_log2);

    // NOTE: rescale旧分母部分
    scores_sum(mi) *= scores_scale;
    // NOTE: 旧分子部分rescale
    assert(size<0>(scores_sum) == size<1>(acc_o) && "sum should have some row with out");
    #pragma unroll
    for (int j = 0; j < size<2>(acc_o); j++) {
      for (int i = 0; i < size<0>(acc_o); i++) {
        acc_o(i, mi, j) *= scores_scale;
      }
    }
  }

  // TODO:
  // flash::scale_apply_exp2(scores, scores_max, softmax_scale_log2);
  // NOTE: rescale所有新分子: QK aka scores
  // NOTE: 使用exp2f
  for (int j  = 0; j < size<1>(scores); j++) {
    for (int i = 0; i < size<2>(scores); i++) {
      for (int k = 0; k < size<0>(scores); k++) {
        scores(k, j, i) = exp2f(scores(k, j, i) * softmax_scale_log2 - scores_max(j));
      }
    }
  }


  // NOTE:累加新分母
  // TODO: 对当前写死
  Tensor scores_sum_cur = make_fragment_like(scores_sum);
  // 1. 线程内累加新分母
  for (int j  = 0; j < size<1>(scores); j++) {
    float local_sum = 0;
    for (int i = 0; i < size<2>(scores); i++) {
      for (int k = 0; k < size<0>(scores); k++) {
        local_sum += scores(k, j, i);
      }
    }
    scores_sum_cur(j) += local_sum;
  }

  // 2. 线程间累加新分母
  SumOp<float> sum_op;
  quad_allreduce_(scores_sum_cur, scores_sum_cur, sum_op);

  // NOTE: 新分母加旧分母
  for (int i = 0; i < size(scores_sum); i++) {
      scores_sum(i) += scores_sum_cur(i);
  }
}

} // namespace flash

template <typename Kernel_traits, typename Params>
__global__ void naive_flash_attention_v2_cutlass_kernel(const Params params) {

  using namespace cute;

  // num_m_block: seqlen group
  const int m_block = blockIdx.x;

  // NOTE: compute at runtime to reduce thread number
  // // num_n_block: dim group
  // const int n_block = blockIdx.y;

  // bs * head
  const int base_offset = blockIdx.z;
  // The thread index.
  const int tidx = threadIdx.x;

  // TODO: 传入泛型
  // NOTE: 小技巧
  using Element = typename Kernel_traits::Element;
  using ElementAccum = typename Kernel_traits::ElementAccum;
  // using TiledMMA = typename Kernel_traits::MMA;
  using TiledMMA = typename Kernel_traits::TiledMma;
  using index_t = typename Kernel_traits::index_t;
  using SmemLayoutQ = typename Kernel_traits::SmemLayoutQ;
  using SmemLayoutK = typename Kernel_traits::SmemLayoutKV;
  using SmemLayoutV = typename Kernel_traits::SmemLayoutKV;
  using SmemLayoutVt = typename Kernel_traits::SmemLayoutVtransposed;
  using SmemLayoutVtNoSwizzle = typename Kernel_traits::SmemLayoutVtransposedNoSwizzle;

  constexpr int kBlockM = Kernel_traits::kBlockM;
  constexpr int kBlockN = Kernel_traits::kBlockN;
  constexpr int kHeadDim = Kernel_traits::kHeadDim;


  // Shared memory.
  extern __shared__ char smem_[];
  using SharedStorage = SharedStorage<Element, SmemLayoutQ, SmemLayoutK, SmemLayoutV>;
  SharedStorage &shared_storage = *reinterpret_cast<SharedStorage *>(smem_);

  // TODO: base offset for MHA
  // NOTE: convert C pointer to Tensor for convenience
  Tensor Q = make_tensor(
      make_gmem_ptr(reinterpret_cast<Element *>(params.q_ptr)),
      make_shape(params.seqlen, params.dim),
      make_stride(params.dim, Int<1>{}));
  Tensor K = make_tensor(
      make_gmem_ptr(reinterpret_cast<Element *>(params.k_ptr)),
      make_shape(params.seqlen, params.dim),
      make_stride(params.dim, Int<1>{}));
  Tensor V = make_tensor(
      make_gmem_ptr(reinterpret_cast<Element *>(params.v_ptr)),
      make_shape(params.seqlen, params.dim),
      make_stride(params.dim, Int<1>{}));
  // transpose V for gemm
  Tensor Vt = make_tensor(
      make_gmem_ptr(reinterpret_cast<Element *>(params.v_ptr)),
      make_shape(params.dim, params.seqlen),
      make_stride(Int<1>{}, params.dim));

  // 加载Q, K, V分块
  // (kBlockM, kHeadDim, num_tile_n)
  Tensor gQ = local_tile(Q, make_tile(Int<kBlockM>{}, Int<kHeadDim>{}), make_coord(m_block, _));

  // (kBlockN, kHeadDim, num_tile_n)
  // NOTE: loading流水线, 初次加载所需K, V
  Tensor gK = local_tile(K, make_tile(Int<kBlockN>{}, Int<kHeadDim>{}), make_coord(0, _));
  Tensor gV = local_tile(V, make_tile(Int<kBlockN>{}, Int<kHeadDim>{}), make_coord(0, _));

  // 获取MMA抽象
  TiledMMA tiled_mma;
  auto thr_mma = tiled_mma.get_slice(tidx);

  // Construct SMEM tensors.
  Tensor sQ = make_tensor(make_smem_ptr(shared_storage.smem_q.data()), SmemLayoutQ{});
  Tensor sK = make_tensor(make_smem_ptr(shared_storage.smem_k.data()), SmemLayoutK{});
  Tensor sV = make_tensor(make_smem_ptr(shared_storage.smem_v.data()), SmemLayoutV{});

  // Tensor for V Transpose; used in GEMM-II.
  Tensor sVt = make_tensor(make_smem_ptr(shared_storage.smem_v.data()), SmemLayoutVt{});
  Tensor sVtNoSwizzle = make_tensor(make_smem_ptr(shared_storage.smem_v.data()), SmemLayoutVtNoSwizzle{});

  // NOTE: copy抽象
  // NOTE: QKV gmem -> smem拷贝的抽象
  typename Kernel_traits::GmemTiledCopyQKV gmem_tiled_copy_QKV;
  auto gmem_thr_copy_QKV = gmem_tiled_copy_QKV.get_thread_slice(tidx);

  // NOTE: 定义gmem -> smem拷贝的src, dst
  Tensor tQgQ = gmem_thr_copy_QKV.partition_S(gQ(_, _, 0));
  Tensor tQsQ = gmem_thr_copy_QKV.partition_D(sQ);
  Tensor tKgK = gmem_thr_copy_QKV.partition_S(gK(_, _, 0));
  Tensor tKsK = gmem_thr_copy_QKV.partition_D(sK);
  Tensor tVgV = gmem_thr_copy_QKV.partition_S(gV(_, _, 0));
  Tensor tVsV = gmem_thr_copy_QKV.partition_D(sV);


  // NOTE: 定义smem -> reg拷贝的dst
  // partition_fragment与partition类似, 只是返回的是寄存器表示
  Tensor tSrQ  = thr_mma.partition_fragment_A(sQ);                           // (MMA,MMA_M,MMA_K)
  Tensor tSrK  = thr_mma.partition_fragment_B(sK);                           // (MMA,MMA_N,MMA_K)
  Tensor tOrVt  = thr_mma.partition_fragment_B(sVtNoSwizzle);                // (MMA, MMA_K,MMA_N)

  //
  // Copy Atom retiling
  //

  // TODO: 理解这里的atom retiling

  // NOTE: 准备拷贝Q, K, V到smem的copy对象
  auto smem_tiled_copy_Q = make_tiled_copy_A(typename Kernel_traits::SmemCopyAtom{}, tiled_mma);
  auto smem_thr_copy_Q = smem_tiled_copy_Q.get_thread_slice(tidx);
  Tensor tSsQ = smem_thr_copy_Q.partition_S(sQ);

  auto smem_tiled_copy_K = make_tiled_copy_B(typename Kernel_traits::SmemCopyAtom{}, tiled_mma);
  auto smem_thr_copy_K = smem_tiled_copy_K.get_thread_slice(tidx);
  Tensor tSsK = smem_thr_copy_K.partition_S(sK);

  // TODO: 拷贝时转置
  // NOTE: smem->reg拷贝Vt
  auto smem_tiled_copy_V = make_tiled_copy_B(typename Kernel_traits::SmemCopyAtomTransposed{}, tiled_mma);
  auto smem_thr_copy_V = smem_tiled_copy_V.get_thread_slice(tidx);
  Tensor tOsVt = smem_thr_copy_V.partition_S(sVt);

  // NOTE: 命名规则, t表示to, s/g表示位置(smem, gmem)
  // 从smem加载时做retiling
  // tKgK表示gmem中的K, 用作gmem->smem的src
  // tKsK表示smem中的K, 用作gmem->smem的dst
  // tSsK表示smem中的K, 用作smem->reg的src


  // NOTE: make_identity_tensor创建只有形状的tensor用于拷贝
  // 在copy时用于跳过整块的block

  // // TODO: cQ等用在causal模式, 暂时无用
  // // Construct identity layout for sQ and sK
  // Tensor cQ = make_identity_tensor(make_shape(size<0>(sQ), size<1>(sQ)));    // (BLK_M,BLK_K) -> (blk_m,blk_k)
  // Tensor cKV = make_identity_tensor(make_shape(size<0>(sK), size<1>(sK)));    // (BLK_N,BLK_K) -> (blk_n,blk_k)

  // // Repeat the partitioning with identity layouts
  // Tensor tQcQ = gmem_thr_copy_QKV.partition_S(cQ);       // (ACPY,ACPY_M,ACPY_K) -> (blk_m,blk_k)
  // Tensor tKVcKV = gmem_thr_copy_QKV.partition_S(cKV);   // (BCPY,BCPY_N,BCPY_K) -> (blk_n,blk_k)

  // 流水线加载初始Q, K
  // 加载Q到smem
  flash::copy(gmem_tiled_copy_QKV, tQgQ, tQsQ);
  // 加载K到smem
  flash::copy(gmem_tiled_copy_QKV, tKgK, tKsK);
  // 开始执行异步拷贝
  cute::cp_async_fence();

  Tensor rAccOut = partition_fragment_C(tiled_mma, Shape<Int<kBlockM>, Int<kHeadDim>>{});

  // step1: slice-k compute QK block
  // Q[BLOCK_M, BLOCK_N] @ K[BLOCK_M, BLOCK_N].T = O[BLOCK_M, BLOCK_M]
  //
  // step2:
  // advance K
  // NOTE: K, V分块的数量: 处理的区间
  const int n_block_min = 0;
  int n_block_max = cute::ceil_div(params.seqlen, kBlockN);

  // NOTE: 需要记录的max
  Tensor scores_max = make_tensor<ElementAccum>(Shape<Int<2 * size<1>(rAccOut)>>{});
  // NOTE: 需要记录的denom
  Tensor scores_sum = make_fragment_like(scores_max);

  clear(rAccOut);


  for (int nbi = n_block_min; nbi < n_block_max; nbi++) {
    auto rAccScore = partition_fragment_C(tiled_mma, make_shape(Int<kBlockM>{}, Int<kBlockN>{}));

    clear(rAccScore);

    // 等待Q, K的gmem -> smem拷贝完成, 即Q, K就绪
    // wait<0>表示等待还剩0个未完成
    flash::cp_async_wait<0>();
    __syncthreads();

    // TODO: gemm的同时异步加载V
    gV = local_tile(V, make_tile(Int<kBlockN>{}, Int<kHeadDim>{}), make_coord(nbi, _));
    tVgV = gmem_thr_copy_QKV.partition_S(gV(_, _, 0));
    // 异步加载V到smem
    flash::copy(gmem_tiled_copy_QKV, tVgV, tVsV);
    // 发起异步拷贝
    cute::cp_async_fence();

    // O = Q@K.T
    // NOTE: 加载smem中的数据到reg再做gemm, **加载期间执行retile**
    flash::gemm_smem(rAccScore, tSrQ, tSrK, tSsQ, tSsK, tiled_mma, smem_tiled_copy_Q, smem_tiled_copy_K,
        smem_thr_copy_Q, smem_thr_copy_K
    );

    // NOTE: 等待V加载完成, 为下个K加载准备初始状态
    flash::cp_async_wait<0>();
    __syncthreads();

    // advance K
    if (nbi != n_block_max - 1) {
      gK = local_tile(K, make_tile(Int<kBlockN>{}, Int<kHeadDim>{}), make_coord(nbi + 1, _));
      tKgK = gmem_thr_copy_QKV.partition_S(gK(_, _, 0));
      flash::copy(gmem_tiled_copy_QKV, tKgK, tKsK);
      cute::cp_async_fence();
    }

    Tensor scores = make_tensor(rAccScore.data(), flash::convert_layout_acc_rowcol(rAccScore.layout()));

    // 计算softmax
    // NOTE: rAccOut记录softmax后所有的分子
    flash::softmax_rescale_o2(scores, scores_max, scores_sum, rAccOut, params.softmax_scale);

    // 实际执行QK @ V
    // (score AKA rAccScore): QK[M, N] @ V[N, dim]
    // NOTE: DABC: F32F16F16F32, convert D type(F32) to A type(F16)
    // TODO: convert_type目前写死
    Tensor rP = flash::convert_type_f32_to_f16(rAccScore);
    // NOTE: Convert from layout C to layout A
    Tensor tOrP = make_tensor(rP.data(), flash::convert_layout_rowcol_Aregs<TiledMMA>(scores.layout()));

    flash::gemm_A_in_regs(rAccOut, tOrP, tOrVt, tOsVt, tiled_mma, smem_tiled_copy_V, smem_thr_copy_V);
  }

  // NOTE: 最后统一除上分母部分
  for (int j  = 0; j < size<1>(rAccOut); j++) {
    float inv_sum = 1.f / scores_sum(j);
    for (int i = 0; i < size<2>(rAccOut); i++) {
      for (int k = 0; k < size<0>(rAccOut); k++) {
        rAccOut(k, j, i) *= inv_sum;
      }
    }
  }


  // Convert acc_o from fp32 to fp16/bf16
  Tensor rO = flash::convert_type_f32_to_f16(rAccOut);
  // 复用sQ的smem做sO的拷出
  Tensor sO = make_tensor(sQ.data(), typename Kernel_traits::SmemLayoutO{});    // (SMEM_M,SMEM_N)

  // Partition sO to match the accumulator partitioning
  // TODO: review
  auto smem_tiled_copy_O = make_tiled_copy_C(typename Kernel_traits::SmemCopyAtomO{}, tiled_mma);
  auto smem_thr_copy_O = smem_tiled_copy_O.get_thread_slice(tidx);
  Tensor taccOrO = smem_thr_copy_O.retile_S(rO);        // ((Atom,AtomNum), MMA_M, MMA_N)
  Tensor taccOsO = smem_thr_copy_O.partition_D(sO);     // ((Atom,AtomNum),PIPE_M,PIPE_N)

  // NOTE: 先拷贝到smem
  cute::copy(smem_tiled_copy_O, taccOrO, taccOsO);

  Tensor O = make_tensor(
      make_gmem_ptr(reinterpret_cast<ElementAccum *>(params.out_ptr)),
      make_shape(params.seqlen, params.dim),
      make_stride(params.dim, Int<1>{}));
  Tensor gO = local_tile(O, make_tile(Int<kBlockM>{}, Int<kHeadDim>{}), make_coord(m_block, _));

  // 创建到smem -> gmem的拷贝
  typename Kernel_traits::GmemTiledCopyO gmem_tiled_copy_O;
  auto gmem_thr_copy_O = gmem_tiled_copy_O.get_thread_slice(tidx);
  Tensor tOsO = gmem_thr_copy_O.partition_S(sO);        // ((Atom,AtomNum),ATOM_M,ATOM_N)
  Tensor tOgO = gmem_thr_copy_O.partition_D(gO(_, _, 0));

  __syncthreads();

  // NOTE:: 再拷贝到gmem

  // TODO: review, 这里两个copy的作用
  Tensor tOrO = make_tensor<Element>(shape(tOgO));
  cute::copy(gmem_tiled_copy_O, tOsO, tOrO);

  flash::copy(gmem_tiled_copy_O, tOrO, tOgO);
}

template <typename Kernel_traits, typename Params>
__global__ void flash_attention_v2_cutlass_kernel(const Params &params) {}

void flash_attention_v2_cuda(FPC *Q, FPC *K, FPC *V, FPC_O *O, int m, int n) {
  using Kernel_traits = Test_Traits;
  using Element = typename Kernel_traits::Element;
  using SmemLayoutQ = typename Kernel_traits::SmemLayoutQ;
  using SmemLayoutK = typename Kernel_traits::SmemLayoutKV;
  using SmemLayoutV = typename Kernel_traits::SmemLayoutKV;

  // Q smem size + KV smem size
  constexpr int kSmemSize = Kernel_traits::kSmemSize;

  int bs = 1;
  int head = 1;
  int seqlen = m;
  int dim = n;
  int bs_stride = head * seqlen * dim;
  int head_stride = seqlen * dim;
  int seqlen_stride = dim;
  int dim_stride = 1;
  // int smem_size = kSmemSize;
  int smem_size = int(sizeof(SharedStorage<Element, SmemLayoutQ, SmemLayoutK, SmemLayoutV>));


  // float softmax_scale = 1.f / sqrtf(static_cast<float>(n));
  float softmax_scale = 1.f;

  Flash_fwd_params params;
  set_params_fprop(params, bs, head, seqlen, dim, bs_stride, head_stride,
                   seqlen_stride, dim_stride, Q, K, V, O, softmax_scale);

  // const int num_m_block =
  //     (params.seqlen + Kernel_traits::kBlockM - 1) / Kernel_traits::kBlockM;
  // assert(params.bs == 1 && params.head == 1 && "bs == head == 1 for testing");
  // dim3 grid(num_m_block, params.bs, params.head);
  // dim3 block(Kernel_traits::kBlockN, 1, 1);

  const int num_m_block =
      (params.seqlen + Kernel_traits::kBlockM - 1) / Kernel_traits::kBlockM;
  // TODO: dim维度分块数量
  const int num_n_block =
      (params.dim + Kernel_traits::kBlockN - 1) / Kernel_traits::kBlockN;

  assert(params.bs == 1 && params.head == 1 && "bs == head == 1 for testing");

  dim3 grid(num_m_block, 1, params.bs * params.head);
  // dim3 block(Kernel_traits::kBlockN, 1, 1);
  dim3 block(size(Kernel_traits::MMA{}));

  // TODO: smem_size
  naive_flash_attention_v2_cutlass_kernel<Kernel_traits>
      <<<grid, block, smem_size>>>(params);
  CUDA_CHECK(cudaGetLastError());

  cudaDeviceSynchronize();
}

void self_attention_cuda(FP *Q, FP *K, FP *V, FP *O, int m, int n) {
  int mBlock = 2;
  assert(m % mBlock == 0 && "mBlock should align");

  // TODO: test
  // float sm_scale = 1.f / sqrtf(static_cast<float>(n));
  float sm_scale = 1.f;
  FP *sm_o;
  cudaMalloc((void **)&sm_o, sizeof(FP) * m * m);

  dim3 qk_block(m / mBlock, 1, 1);
  naive_nrow_gemm<<<1, qk_block>>>(Q, K, sm_o, sm_scale, 0, m, m, n, mBlock);
  cudaDeviceSynchronize();
  DEBUG_BLOCK(CUDA_CHECK(cudaGetLastError()); 
      printf("== naive QK ==\n");
      print_device_matrix(sm_o, m, m);
      );

  {
    // TODO: test QK only
    FP *h_sm_o = new FP[m * m];
    cudaMemcpy(h_sm_o, sm_o, sizeof(FP) * m * m, cudaMemcpyDeviceToHost);
    Tensor Self = make_tensor(h_sm_o, make_shape(m, m), make_stride(m, 1));
    auto tile = make_tile(8, 8);
    auto coor = make_coord(TX, TY);
    Tensor tSelf = local_tile(Self, tile, coor);
    print("self QK: \n");
    print_tensor(local_tile(Self, tile, make_coord(0, 0)));
    print("x,1:\n");
    print_tensor(local_tile(Self, tile, make_coord(0, 1)));
    free(h_sm_o);
  }

  // QK[M, M]
  dim3 sm_block(m, 1, 1);
  row_softmax<<<1, sm_block>>>(sm_o, sm_o, m);
  cudaDeviceSynchronize();
  DEBUG_BLOCK(CUDA_CHECK(cudaGetLastError());
              printf("== naive softmax(QK) ==\n");
              print_device_matrix(sm_o, m, m););
  {
    // TODO: test QK only
    FP *h_sm_o = new FP[m * m];
    cudaMemcpy(h_sm_o, sm_o, sizeof(FP) * m * m, cudaMemcpyDeviceToHost);
    Tensor Self = make_tensor(h_sm_o, make_shape(m, m), make_stride(m, 1));
    auto tile = make_tile(8, 8);
    auto coor = make_coord(TX, TY);
    Tensor tSelf = local_tile(Self, tile, coor);
    print("self softmax(QK): \n");
    print_tensor(tSelf);
    free(h_sm_o);
  }

  // QK[M, M] @ V[M, N]
  dim3 qkv_block(m / mBlock, 1, 1);
  naive_pv<<<1, qkv_block>>>(sm_o, V, O, m, n, mBlock);
  cudaDeviceSynchronize();
  DEBUG_BLOCK(CUDA_CHECK(cudaGetLastError());
              printf("== naive softmax(QK)V ==\n");
              print_device_matrix(O, m, n););

  {
    FP *h_sm_o = new FP[m * n];
    cudaMemcpy(h_sm_o, O, sizeof(FP) * m * n, cudaMemcpyDeviceToHost);
    Tensor Self = make_tensor(h_sm_o, make_shape(m, n), make_stride(n, 1));
    auto tile = make_tile(8, 8);
    auto coor = make_coord(TX, TY);
    print("self O: \n");
    print_tensor(local_tile(Self, tile, make_coord(0, 0)));
    print("x,1:\n");
    print_tensor(local_tile(Self, tile, make_coord(0, 1)));
    free(h_sm_o);
  }

  cudaFree(sm_o);
}

// naive gemm implement with slice-k
// perform C = aA@B + bC
// A[M, K] x B[K, N] = C[M, N]
// each thread process mblock rows of A
__global__ void naive_nrow_gemm(FP *A, FP *B, FP *C, FP a, FP b,
                                int M, int N, int K, int mBlock) {
  int idx = threadIdx.x + blockDim.x * blockIdx.x;

  // each thread process a range of rows
  idx *= mBlock;

  // A[mBlock, K] x B[N, K].T = C[mBlock, N]
  for (int i = idx; i < idx + mBlock; i++) {
    for (int j = 0; j < N; j++) {
      FP sum = 0.f;
      for (int k = 0; k < K; k++) {
        sum += A[i * K + k] * B[j * K + k];
      }
      // C[M, N]
      // C = aA@B + bC
      C[i * N + j] = a * sum + b * C[i * N + j];
    }
  }
}

// perform QK[M, M] @ V[M, N]
__global__ void naive_pv(FP *P, FP *V, FP *O, int M, int N,
                         int mBlock) {
  int idx = threadIdx.x + blockDim.x * blockIdx.x;

  // each thread process a range of rows
  idx *= mBlock;

  int K = M;
  // P[mBlock, M] x V[M, N] = O[mBlock, N]
  for (int i = idx; i < idx + mBlock; i++) {
    for (int j = 0; j < N; j++) {
      FP sum = 0.f;
      for (int k = 0; k < K; k++) {
        sum += P[i * K + k] * V[k * N + j];
      }
      // C[M, N]
      O[i * N + j] = sum;
    }
  }
}

// each thread process one row of softmax
__global__ void row_softmax(FP *input, FP *output, int n) {
  // assume id will not exceed row number of input
  int idx = threadIdx.x + blockDim.x * blockIdx.x;

  FP max = -INFINITY;
  FP sum = 0.f;

  // Find max
  for (int i = 0; i < n; i++) {
    if (input[idx * n + i] > max) {
      max = input[idx * n + i];
    }
  }

  // Compute numerator and denominator
  for (int i = 0; i < n; i++) {
    output[idx * n + i] = exp2(input[idx * n + i] - max);
    sum += output[idx * n + i];
  }

  // Compute softmax
  for (int i = 0; i < n; i++) {
    output[idx * n + i] /= sum;
  }
}

// print matrix
template <typename T>
void print_host_matrix(T *matrix, int m, int n) {
  for (int i = 0; i < m; i++) {
    for (int j = 0; j < n; j++) {
      printf("%f, ", matrix[i * n + j]);
    }
    printf("\n");
  }
}

template <typename T>
void print_device_matrix(T *dev_ptr, int m, int n) {
  T *host_ptr = new T[m * n];
  cudaMemcpy(host_ptr, dev_ptr, sizeof(T) * m * n, cudaMemcpyDeviceToHost);

  for (int i = 0; i < m; i++) {
    for (int j = 0; j < n; j++) {
      printf("%.4f ", (float)host_ptr[i * n + j]);
    }
    printf("\n");
  }
  free(host_ptr);
}

void test_attention() {
  // seqlen
  int m = Input_seq;
  // dim
  int n = Dim;

  // Host pointer
  FP *h_K = new FP[m * n];
  FP *h_Q = new FP[m * n];
  FP *h_V = new FP[m * n];
  FP *h_O = new FP[m * n];

  FPC *h_K2 = new FPC[m * n];
  FPC *h_Q2 = new FPC[m * n];
  FPC *h_V2 = new FPC[m * n];
  FPC_O *h_O2 = new FPC_O[m * n];

  // 初始化 K, Q, V
  for (int i = 0; i < m * n; ++i) {
    // h_K[i] = static_cast<FP>(rand()) / RAND_MAX;
    // h_Q[i] = static_cast<FP>(rand()) / RAND_MAX;
    // h_V[i] = static_cast<FP>(rand()) / RAND_MAX;
    h_K[i] = static_cast<FP>(0.0001f * i);
    h_Q[i] = static_cast<FP>(0.0001f * i);
    h_V[i] = static_cast<FP>(0.0001f * i);

    h_Q2[i] = FPC(h_Q[i]);
    h_K2[i] = FPC(h_K[i]);
    h_V2[i] = FPC(h_V[i]);
  }

  FP *d_K, *d_Q, *d_V, *d_O;
  FPC *d_K2, *d_Q2, *d_V2;
  FPC_O *d_O2;
  // Malloc device memory
  cudaMalloc((void **)&d_K, sizeof(FP) * m * n);
  cudaMalloc((void **)&d_Q, sizeof(FP) * m * n);
  cudaMalloc((void **)&d_V, sizeof(FP) * m * n);
  cudaMalloc((void **)&d_O, sizeof(FP) * m * n);

  cudaMalloc((void **)&d_K2, sizeof(FPC) * m * n);
  cudaMalloc((void **)&d_Q2, sizeof(FPC) * m * n);
  cudaMalloc((void **)&d_V2, sizeof(FPC) * m * n);
  cudaMalloc((void **)&d_O2, sizeof(FPC_O) * m * n);

  // Copy data from host to device
  cudaMemcpy(d_K, h_K, sizeof(FP) * m * n, cudaMemcpyHostToDevice);
  cudaMemcpy(d_Q, h_Q, sizeof(FP) * m * n, cudaMemcpyHostToDevice);
  cudaMemcpy(d_V, h_V, sizeof(FP) * m * n, cudaMemcpyHostToDevice);

  cudaMemcpy(d_K2, h_K2, sizeof(FPC) * m * n, cudaMemcpyHostToDevice);
  cudaMemcpy(d_Q2, h_Q2, sizeof(FPC) * m * n, cudaMemcpyHostToDevice);
  cudaMemcpy(d_V2, h_V2, sizeof(FPC) * m * n, cudaMemcpyHostToDevice);

  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);
  cudaEventRecord(start, 0);

  // Run test
  for (int i = 0; i < 1; i++) {
    // Launch kernel
    self_attention_cuda(d_Q, d_K, d_V, d_O, m, n);

    CUDA_CHECK(cudaGetLastError());
  }

  // test flash attention 2
  for (int i = 0; i < 1; i++) {
    flash_attention_v2_cuda(d_Q2, d_K2, d_V2, d_O2, m, n);
    CUDA_CHECK(cudaGetLastError());
  }
  cudaDeviceSynchronize();

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  float milliseconds = 0;
  cudaEventElapsedTime(&milliseconds, start, stop);
  printf("Time for kernel execution: %.3f ms \n", milliseconds / 100);
  cudaEventDestroy(start);
  cudaEventDestroy(stop);

  // Result back to host
  cudaMemcpy(h_O, d_O, sizeof(FP) * m * n, cudaMemcpyDeviceToHost);
  cudaMemcpy(h_O2, d_O2, sizeof(FPC_O) * m * n, cudaMemcpyDeviceToHost);

  cudaDeviceSynchronize();

  // assert(all_close(h_O, h_O2, m, n) && "flash attention 1 != flash attention
  // 2");


  Tensor Cute = make_tensor(h_O2, make_shape(m, n), make_stride(n, 1));
  auto tile = make_tile(8, 8);
  auto coor = make_coord(TX, TY);
  Tensor tCute = local_tile(Cute, tile, coor);
  print("cute: \n");
  print_tensor(local_tile(Cute, tile, make_coord(0, 0)));
  print_tensor(local_tile(Cute, tile, make_coord(0, 1)));
  // print_tensor(local_tile(Cute, tile, make_coord(0, 2)));
  // print_tensor(local_tile(Cute, tile, make_coord(0, 3)));
  // print_tensor(Cute);


  cudaFree(d_K);
  cudaFree(d_Q);
  cudaFree(d_V);
  cudaFree(d_O);
  cudaFree(d_K2);
  cudaFree(d_Q2);
  cudaFree(d_V2);
  cudaFree(d_O2);
  free(h_Q);
  free(h_K);
  free(h_V);
  free(h_O);
  free(h_Q2);
  free(h_K2);
  free(h_V2);
  free(h_O2);
}

template <typename T, typename U>
bool all_close(T *A, U *B, int m, int n) {
  for (int i = 0; i < m * n; i++) {
    if (fabs(A[i] - B[i]) > 1e-5) {
      printf("A[%d] = %f, B[%d] = %f\n", i, A[i], i, B[i]);
      return false;
    }
  }
  return true;
}

int main() {
  int epoch = 1;
  for (int i = 0; i < epoch; i++)
    test_attention();

  return 0;
}
