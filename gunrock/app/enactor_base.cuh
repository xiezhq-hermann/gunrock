// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * enactor_base.cuh
 *
 * @brief Base Graph Problem Enactor
 */

#pragma once

#include <gunrock/util/cuda_properties.cuh>
#include <gunrock/util/cta_work_progress.cuh>
#include <gunrock/util/error_utils.cuh>
#include <gunrock/util/test_utils.cuh>
#include <gunrock/util/array_utils.cuh>
#include <gunrock/app/problem_base.cuh>

#include <gunrock/oprtr/advance/kernel_policy.cuh>

#include <moderngpu.cuh>

using namespace mgpu;

namespace gunrock {
namespace app {

struct EnactorStats
{
    long long           iteration;
//    int                 num_gpus;
//    int                 gpu_idx;

    unsigned long long  total_lifetimes;
    unsigned long long  total_runtimes;
    unsigned long long  total_queued;

    unsigned int        advance_grid_size;
    unsigned int        filter_grid_size;

    util::KernelRuntimeStatsLifetime advance_kernel_stats;
    util::KernelRuntimeStatsLifetime filter_kernel_stats;

    //unsigned int        *d_node_locks;
    //unsigned int        *d_node_locks_out;
    util::Array1D<int, unsigned int> node_locks;
    util::Array1D<int, unsigned int> node_locks_out;

    volatile int       *done;
    int                *d_done;
    cudaEvent_t        throttle_event;
    cudaError_t        retval;
};

struct FrontierAttribute
{
    unsigned int        queue_length;
    unsigned int        queue_index;
    int                 selector;
    bool                queue_reset;
    int                 current_label;
    gunrock::oprtr::advance::TYPE   advance_type;
};

bool All_Done(EnactorStats *enactor_stats,int num_gpus)
{   
    for (int gpu=0;gpu<num_gpus;gpu++)
    if (enactor_stats[gpu].retval!=cudaSuccess)
    {   
        printf("(CUDA error %d @ GPU %d: %s\n", enactor_stats[gpu].retval, gpu, cudaGetErrorString(enactor_stats[gpu].retval)); fflush(stdout);
        return true;
    }   

    for (int gpu=0;gpu<num_gpus;gpu++)
    if (enactor_stats[gpu].done[0]!=0)
    {   
        return false;
    }   
    return true;
} 

    template <typename VertexId, typename SizeT>
    __global__ void Copy_Preds (
        const SizeT     num_elements,
        const VertexId* keys,
        const VertexId* in_preds,
              VertexId* out_preds)
    {   
        VertexId x = ((blockIdx.y*gridDim.x+blockIdx.x)*blockDim.y+threadIdx.y)*blockDim.x+threadIdx.x;
        if (x>=num_elements) return;
        VertexId t = keys[x];
        out_preds[x]=in_preds[t];
    }   

    template <typename VertexId, typename SizeT>
    __global__ void Update_Preds (
        const SizeT     num_elements,
        const VertexId* keys,
        const VertexId* org_vertexs,
        const VertexId* in_preds,
              VertexId* out_preds)
    {   
        VertexId x = ((blockIdx.y*gridDim.x+blockIdx.x)*blockDim.y+threadIdx.y)*blockDim.x+threadIdx.x;
        /*long long x= blockIdx.y;
        x = x*gridDim.x+blockIdx.x;
        x = x*blockDim.y+threadIdx.y;
        x = x*blockDim.x+threadIdx.x;*/

        if (x>=num_elements) return;
        VertexId t = keys[x];
        VertexId p = in_preds[x];
        out_preds[t]=org_vertexs[p];
    }   

/**
 * @brief Base class for graph problem enactors.
 */
class EnactorBase
{
public:  

    int                             num_gpus;
    int                             *gpu_idx;
    //Device properties
    //util::CudaProperties            cuda_props;
    util::CudaProperties            *cuda_props;

    // Queue size counters and accompanying functionality
    //util::CtaWorkProgressLifetime   work_progress;
    util::CtaWorkProgressLifetime   *work_progress;

    FrontierType                    frontier_type;

    //EnactorStats                    enactor_stats;
    EnactorStats                    *enactor_stats;

    //FrontierAttribute               frontier_attribute;
    FrontierAttribute               *frontier_attribute;

public:

    // if DEBUG is set, print details to stdout
    bool DEBUG;

    FrontierType GetFrontierType() { return frontier_type;}

protected:  

    /**
     * @brief Constructor
     *
     * @param[in] frontier_type The frontier type (i.e., edge/vertex/mixed)
     * @param[in] DEBUG If set, will collect kernel running stats and display the running info.
     */
    EnactorBase(FrontierType frontier_type, bool DEBUG,
                int num_gpus, int* gpu_idx) :
        frontier_type(frontier_type),
        DEBUG(DEBUG)
    {
        util::cpu_mt::PrintMessage("EnactorBase() begin.");
        this->num_gpus     = num_gpus;
        this->gpu_idx      = gpu_idx;
        cuda_props         = new util::CudaProperties          [num_gpus];
        work_progress      = new util::CtaWorkProgressLifetime [num_gpus];
        enactor_stats      = new EnactorStats                  [num_gpus];
        frontier_attribute = new FrontierAttribute             [num_gpus];

        for (int gpu=0;gpu<num_gpus;gpu++)
        {
            if (util::SetDevice(gpu_idx[gpu])) return;
            // Setup work progress (only needs doing once since we maintain
            // it in our kernel code)
            work_progress[gpu].Setup();
            cuda_props   [gpu].Setup(gpu_idx[gpu]);
            //enactor_stats[gpu].num_gpus = num_gpus;
            //enactor_stats[gpu].gpu_idx  = gpu_idx[gpu];
            enactor_stats[gpu].node_locks    .SetName("node_locks"    );
            enactor_stats[gpu].node_locks_out.SetName("node_locks_out");
            //enactor_stats.d_node_locks = NULL;
            //enactor_stats.d_node_locks_out = NULL;
        }
        util::cpu_mt::PrintMessage("EnactorBase() end.");
    }


    virtual ~EnactorBase()
    {
        util::cpu_mt::PrintMessage("~EnactorBase() begin.");
        for (int gpu=0;gpu<num_gpus;gpu++)
        {
            if (util::SetDevice(gpu_idx[gpu])) return;
            enactor_stats[gpu].node_locks    .Release();
            enactor_stats[gpu].node_locks_out.Release();
            if (work_progress[gpu].HostReset()) return;
            if (util::GRError(cudaFreeHost((void*)enactor_stats[gpu].done), 
                 "EnactorBase cudaFreeHost done failed", __FILE__, __LINE__)) return;
            if (util::GRError(cudaEventDestroy(enactor_stats[gpu].throttle_event),
                 "EnactorBase cudaEventDestroy throttle_event failed", __FILE__, __LINE__)) return;
            //if (enactor_stats.d_node_locks) util::GRError(cudaFree(enactor_stats.d_node_locks), "EnactorBase cudaFree d_node_locks failed", __FILE__, __LINE__);
            //if (enactor_stats.d_node_locks_out) util::GRError(cudaFree(enactor_stats.d_node_locks_out), "EnactorBase cudaFree d_node_locks_out failed", __FILE__, __LINE__);
        }
        delete[] work_progress     ; work_progress      = NULL;
        delete[] cuda_props        ; cuda_props         = NULL;
        delete[] enactor_stats     ; enactor_stats      = NULL;
        delete[] frontier_attribute; frontier_attribute = NULL;
        util::cpu_mt::PrintMessage("~EnactorBase() end.");
    }

    template <typename ProblemData>
    cudaError_t Setup(
        ProblemData *problem,
        int max_grid_size,
        int advance_occupancy,
        int filter_occupancy,
        int node_lock_size = 256)
    {
        util::cpu_mt::PrintMessage("EnactorBase Setup() begin.");
        cudaError_t retval = cudaSuccess;

        for (int gpu=0;gpu<num_gpus;gpu++)
        {
            if (retval = util::SetDevice(gpu_idx[gpu])) return retval;
            //initialize runtime stats
            enactor_stats[gpu].advance_grid_size = MaxGridSize(gpu, advance_occupancy, max_grid_size);
            enactor_stats[gpu].filter_grid_size  = MaxGridSize(gpu, filter_occupancy, max_grid_size);

            if (retval = enactor_stats[gpu].advance_kernel_stats.Setup(enactor_stats[gpu].advance_grid_size)) return retval;
            if (retval = enactor_stats[gpu]. filter_kernel_stats.Setup(enactor_stats[gpu]. filter_grid_size)) return retval;
            //initialize the host-mapped "done"
            int flags = cudaHostAllocMapped;

            // Allocate pinned memory for done
            if (retval = util::GRError(cudaHostAlloc((void**)&(enactor_stats[gpu].done), sizeof(int) * 1, flags),
                    "BFSEnactor cudaHostAlloc done failed", __FILE__, __LINE__)) return retval;

            // Map done into GPU space
            if (retval = util::GRError(cudaHostGetDevicePointer((void**)&(enactor_stats[gpu].d_done), (void*) enactor_stats[gpu].done, 0),  
                    "BFSEnactor cudaHostGetDevicePointer done failed", __FILE__, __LINE__)) return retval;

            // Create throttle event
            if (retval = util::GRError(cudaEventCreateWithFlags(&enactor_stats[gpu].throttle_event, cudaEventDisableTiming),                
                    "BFSEnactor cudaEventCreateWithFlags throttle_event failed", __FILE__, __LINE__)) return retval;
                
            enactor_stats[gpu].iteration             = 0;
            enactor_stats[gpu].total_runtimes        = 0;
            enactor_stats[gpu].total_lifetimes       = 0;
            enactor_stats[gpu].total_queued          = 0;
            enactor_stats[gpu].done[0]               = -1;
            enactor_stats[gpu].retval                = cudaSuccess;
            //enactor_stats.num_gpus              = 1;
            //enactor_stats.gpu_id                = 0;

            //if (retval = util::GRError(cudaMalloc(
            //                (void**)&enactor_stats.d_node_locks,
            //                node_lock_size * sizeof(unsigned int)),
            //            "EnactorBase cudaMalloc d_node_locks failed", __FILE__, __LINE__)) return retval;
            if (retval = enactor_stats[gpu].node_locks.Allocate(node_lock_size,util::DEVICE)) return retval;

            //if (retval = util::GRError(cudaMalloc(
            //                (void**)&enactor_stats.d_node_locks_out,
            //                node_lock_size * sizeof(unsigned int)),
            //            "EnactorBase cudaMalloc d_node_locks_out failed", __FILE__, __LINE__)) return retval;
            if (retval = enactor_stats[gpu].node_locks_out.Allocate(node_lock_size, util::DEVICE)) return retval;
        }
        util::cpu_mt::PrintMessage("EnactorBase Setup() end.");
        return retval;
    }

    /**
     * @brief Utility function for getting the max grid size.
     *
     * @param[in] cta_occupancy CTA occupancy for current architecture
     * @param[in] max_grid_size Preset max grid size. If less or equal to 0, fully populate all SMs
     *
     * \return The maximum number of threadblocks this enactor class can launch.
     */
    int MaxGridSize(int gpu, int cta_occupancy, int max_grid_size = 0)
    {
        if (max_grid_size <= 0) {
            max_grid_size = this->cuda_props[gpu].device_props.multiProcessorCount * cta_occupancy;
        }

        return max_grid_size;
    } 
};


} // namespace app
} // namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End: