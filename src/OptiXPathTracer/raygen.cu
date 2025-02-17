//
// Copyright (c) 2021, NVIDIA CORPORATION. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//  * Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
//  * Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//  * Neither the name of NVIDIA CORPORATION nor the names of its
//    contributors may be used to endorse or promote products derived
//    from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
#include <optix.h>

#include <cuda/LocalGeometry.h>
#include <cuda/LocalShading.h>
#include <cuda/helpers.h>
#include <cuda/random.h>
#include <sutil/vec_math.h>
#include "BDPTVertex.h"
#include "cuProg.h"
#include"rmis.h"
//------------------------------------------------------------------------------
//
//
//
//------------------------------------------------------------------------------
#define ISINVALIDVALUE(ans) (ans.x>100000.0f|| isnan(ans.x)||ans.y>100000.0f|| isnan(ans.y)||ans.z>100000.0f|| isnan(ans.z))
 
__device__ inline float4 ToneMap_exposure(const float4& c, float exposure)
{
    float3 ldr = make_float3(1.0) - make_float3(exp(-c.x * exposure), exp(-c.y * exposure), exp(-c.z * exposure));
    return make_float4(ldr.x, ldr.y, ldr.z, 1.0f);
}
__device__ inline float4 ToneMap(const float4& c, float limit)
{
    //return ToneMap_exposure(c,limit);

    float luminance = 0.3f * c.x + 0.6f * c.y + 0.1f * c.z;

    float4 col = c * 1.0f / (1.0f + 1 * luminance / limit);
    return make_float4(col.x, col.y, col.z, 1.0f);
}

__device__ inline float color2luminance(const float3& c)
{
    return 0.3f * c.x + 0.6f * c.y + 0.1f * c.z;
}
__device__ inline float4 LinearToSrgb(const float4& c)
{
    const float kInvGamma = 1.0f / 2.2f;
    return make_float4(powf(c.x, kInvGamma), powf(c.y, kInvGamma), powf(c.z, kInvGamma), c.w);
}


extern "C" __global__ void __raygen__pinhole()
{  
    const uint3  launch_idx = optixGetLaunchIndex();
    const uint3  launch_dims = optixGetLaunchDimensions();
    const float3 eye = Tracer::params.eye;
    const float3 U = Tracer::params.U;
    const float3 V = Tracer::params.V;
    const float3 W = Tracer::params.W;
    const int    subframe_index = Tracer::params.subframe_index;
     
    float3 normalizeV = normalize(V);
    if (launch_idx.x == 0 && launch_idx.y == 0)
    {
        //printf("V:%f %f %f\n",normalizeV.x, normalizeV.y, normalizeV.z);
    }
    //if (launch_idx.x == 0 && launch_idx.y == 0)
    //{
    //    printf("launch dim %d %d\n", launch_dims.x, launch_dims.y); 
    //    printf("light source number %d\n", Tracer::params.lights.count);
    //    for (int i = 0; i < Tracer::params.lights.count; i++)
    //    {
    //        printf("lightsource id %d\n", i);
    //        printf("lightsource type %d\n", reinterpret_cast<Light*>( Tracer::params.lights.data)[i].type);
    //        printf("--------------------\n");
    //    }
    //}
    //
    // Generate camera ray
    //
    unsigned int seed = tea<4>( launch_idx.y * launch_dims.x + launch_idx.x, subframe_index );

    // The center of each pixel is at fraction (0.5,0.5)
    const float2 subpixel_jitter =
        subframe_index == 0 ? make_float2( 0.5f, 0.5f ) : make_float2( rnd( seed ), rnd( seed ) );

    const float2 d =
        2.0f
            * make_float2( ( static_cast<float>( launch_idx.x ) + subpixel_jitter.x ) / static_cast<float>( launch_dims.x ),
                           ( static_cast<float>( launch_idx.y ) + subpixel_jitter.y ) / static_cast<float>( launch_dims.y ) )
        - 1.0f;
    float3 ray_direction = normalize( d.x * U + d.y * V + W );
    float3 ray_origin    = eye;

    //
    // Trace camera ray
    //
    Tracer::PayloadRadiance payload; 
    payload.seed          = seed; 
    payload.origin        = eye;
    payload.ray_direction = ray_direction;
    //payload.throughput    = make_float3(1.0);
    //payload.result = make_float3(0.0);
    payload.currentResult = make_float3(0);
    while (true)
    {
        ray_direction = payload.ray_direction;
        ray_origin = payload.origin; 
        Tracer::traceRadiance(Tracer::params.handle, ray_origin, ray_direction,
            SCENE_EPSILON,  // tmin
            1e16f,  // tmax
            &payload);


        if (float3weight(payload.currentResult)> 0.0)
        {
            const float  L_dist = length(payload.vis_pos_A- payload.vis_pos_B);
            const float3 L = (payload.vis_pos_B - payload.vis_pos_A) / L_dist;
            if (Tracer::visibilityTest(Tracer::params.handle, payload.vis_pos_A, payload.vis_pos_B))
            {
                payload.result += payload.currentResult; 
            }
            payload.currentResult = make_float3(0);
        }
        if (payload.done || payload.depth > 30)
        {
            break;
        }
        //break;
        payload.depth += 1;
        
    }
  

    //
    // Update results 
    //
    const unsigned int image_index = launch_idx.y * launch_dims.x + launch_idx.x;
    float3             accum_color = payload.result;

    if( subframe_index > 0 )
    {
        const float  a                = 1.0f / static_cast<float>( subframe_index + 1 );
        const float3 accum_color_prev = make_float3( Tracer::params.accum_buffer[image_index] );
        accum_color                   = lerp( accum_color_prev, accum_color, a );
    }
    Tracer::params.accum_buffer[image_index] = make_float4( accum_color, 1.0f );

    float4 val = ToneMap(make_float4(accum_color, 0.0), 1.5);
    Tracer::params.frame_buffer[image_index] = make_color( make_float3(val) );
} 

RT_FUNCTION void init_vertex_from_lightSample(Tracer::lightSample& light_sample, BDPTVertex& v)
{  
    v.position = light_sample.position;
    v.normal = light_sample.normal();
    v.flux = light_sample.emission;
    v.pdf = light_sample.pdf;
    v.singlePdf = v.pdf;
    v.isOrigin = true;
    v.isBrdf = false;
    v.subspaceId = light_sample.subspaceId;
    v.depth = 0;
    v.materialId = light_sample.bindLight->id;
    v.RMIS_pointer = 1;
    v.uv = light_sample.uv;
    if (light_sample.bindLight->type == Light::Type::QUAD)
    {
        v.type = LightType::QUAD;
    }
    else if (light_sample.bindLight->type == Light::Type::ENV)
    {
        v.type = LightType::ENV;
    }
    //其他光源的状况待补充
}
RT_FUNCTION void init_lightSubPath_from_lightSample(Tracer::lightSample& light_sample, BDPTPath& p)
{
    p.clear();
    p.push();
    BDPTVertex& v = p.currentVertex();
     
    if (light_sample.bindLight->type == Light::Type::QUAD)
    {
        p.nextVertex().singlePdf = light_sample.dir_pdf;
    }
    else if (light_sample.bindLight->type == Light::Type::ENV)
    {
        p.nextVertex().singlePdf = light_sample.dir_pos_pdf;
    }

    init_vertex_from_lightSample(light_sample, v);
     //其他光源的状况待补充
}


RT_FUNCTION void init_EyeSubpath(BDPTPath& p, float3 origin, float3 direction)
{
    p.push();
    p.currentVertex().position = origin;
    p.currentVertex().flux = make_float3(1.0);
    p.currentVertex().pdf = 1.0f;
    p.currentVertex().RMIS_pointer = 0;
    p.currentVertex().normal = direction;
    p.currentVertex().isOrigin = true;
    p.currentVertex().depth = 0;
    p.currentVertex().singlePdf = 1.0;


    p.nextVertex().singlePdf = 1.0f;
     
}


__device__ float3 direction_connect_ZGCBPT(const BDPTVertex& a, const BDPTVertex& b)
{
    float3 L = make_float3(0.0f);
    float3 connectDir = -b.normal; 
    if (dot(a.normal, connectDir) > 0.0)
    {
        MaterialData::Pbr mat_a = Tracer::params.materials[a.materialId];
        mat_a.base_color = make_float4(a.color, 1.0);
        float3 f = Tracer::Eval(mat_a, a.normal, normalize(a.lastPosition - a.position), connectDir)
            * dot(a.normal, connectDir);
        L = a.flux / a.pdf * f * b.flux / b.pdf * rmis::connection_direction_lightSource(a, b);
    }
    if (ISINVALIDVALUE(L))
    {
        return make_float3(0.0f);
    }
    return L;

}
__device__  float3 connectVertex_SPCBPT(const BDPTVertex& a, const BDPTVertex& b)
{
    if (b.is_DIRECTION())
    {
        return direction_connect_ZGCBPT(a, b);
    }
    float3 connectVec = a.position - b.position;
    float3 connectDir = normalize(connectVec);
    float G = abs(dot(a.normal, connectDir)) * abs(dot(b.normal, connectDir)) / dot(connectVec, connectVec);
    float3 LA = a.lastPosition - a.position;
    float3 LA_DIR = normalize(LA);
    float3 LB = b.lastPosition - b.position;
    float3 LB_DIR = normalize(LB); 

    float3 fa, fb;
    float3 ADcolor;
    MaterialData::Pbr mat_a = Tracer::params.materials[a.materialId];
    mat_a.base_color = make_float4(a.color, 1.0); 
    fa = Tracer::Eval(mat_a, a.normal, -connectDir, LA_DIR) / (mat_a.brdf ? abs(dot(a.normal, connectDir)) : 1.0f);

    MaterialData::Pbr mat_b;
    if (!b.isOrigin)
    {
        mat_b = Tracer::params.materials[b.materialId];
        mat_b.base_color = make_float4(b.color,1.0);
        fb = Tracer::Eval(mat_b, b.normal, connectDir, LB_DIR) / (mat_b.brdf ? abs(dot(b.normal, connectDir)) : 1.0f);
    }
    else
    {
        if (dot(b.normal, -connectDir) > 0.0f)
        {
            fb = make_float3(0.0f);
        }
        else
        {
            fb = make_float3(1.0f);
        }
    }
    float3 temp_vec = a.flux / a.pdf;
    //printf("connect info %f %f %f\n", temp_vec.x, temp_vec.y, temp_vec.z);
    float3 contri = a.flux * b.flux * fa * fb * G;
    float pdf = a.pdf * b.pdf; 
    float3 ans = contri / pdf *(b.depth == 0 ? rmis::connection_lightSource(a, b) : rmis::general_connection(a, b));


    if (ISINVALIDVALUE(ans))
    {
        return make_float3(0.0f);
    }
    return  ans;
}

RT_FUNCTION float3 lightStraghtHit(BDPTVertex& a)
{
    float3 contri = a.flux;
    float pdf = a.pdf;
    float inver_weight = a.RMIS_pointer;

    float3 ans = contri / pdf / inver_weight;
    if (ISINVALIDVALUE(ans))
    {
        return make_float3(0.0f);
    }
    return  ans;
}

extern "C" __global__ void __raygen__SPCBPT()
{
    const uint3  launch_idx = optixGetLaunchIndex();
    const uint3  launch_dims = optixGetLaunchDimensions();
    const float3 eye = Tracer::params.eye;
    const float3 U = Tracer::params.U;
    const float3 V = Tracer::params.V;
    const float3 W = Tracer::params.W;
    const int    subframe_index = Tracer::params.subframe_index;

    float3 normalizeV = normalize(V); 
    // Generate camera ray
    //
    unsigned int seed = tea<4>(launch_idx.y * launch_dims.x + launch_idx.x, subframe_index);

    // The center of each pixel is at fraction (0.5,0.5)
    const float2 subpixel_jitter =
        subframe_index == 0 ? make_float2(0.5f, 0.5f) : make_float2(rnd(seed), rnd(seed));

    const float2 d =
        2.0f
        * make_float2((static_cast<float>(launch_idx.x) + subpixel_jitter.x) / static_cast<float>(launch_dims.x),
            (static_cast<float>(launch_idx.y) + subpixel_jitter.y) / static_cast<float>(launch_dims.y))
        - 1.0f;
    float3 ray_direction = normalize(d.x * U + d.y * V + W);
    float3 ray_origin = eye;
    float3 result = make_float3(0);

    Tracer::PayloadBDPTVertex payload;
    payload.clear();
    payload.seed = seed; 
    payload.ray_direction = ray_direction;
    payload.origin = ray_origin;
    
    init_EyeSubpath(payload.path, ray_origin, ray_direction);

       
    unsigned first_hit_id;
    while (true)
    {
        ray_direction = payload.ray_direction;
        ray_origin = payload.origin;
        if (payload.done || payload.depth > 50)
        {
            break;
        }
        int begin_depth = payload.path.size;
        Tracer::traceEyeSubPath(Tracer::params.handle, ray_origin, ray_direction,
            SCENE_EPSILON,  // tmin
            1e16f,  // tmax
            &payload);
        if (payload.path.size == begin_depth)
        {
            break;
        }
        payload.depth += 1;


        //if (payload.path.size == 2)
        //{
        //    BDPTVertex v = payload.path.currentVertex();
        //    labelUnit lu(v.position, v.normal, normalize(v.lastPosition - v.position), false);
        //    first_hit_id = lu.getLabel();
        //}  
        if (payload.path.hit_lightSource())
        {
            float3 res = lightStraghtHit(payload.path.currentVertex());
            result += res;
            break;
        }
        BDPTVertex& eye_subpath = payload.path.currentVertex();
        for (int it = 0; it < CONNECTION_N; it++)
        {

            int light_id = 0;
            float pmf_firstStage = 1;
            if (Tracer::params.subspace_info.light_tree)
            {
                light_id =
                    reinterpret_cast<Tracer::SubspaceSampler_device*>(&Tracer::params.sampler)->sampleFirstStage(eye_subpath.subspaceId, payload.seed, pmf_firstStage);
            }
            if (Tracer::params.sampler.subspace[light_id].size == 0)
            {
                continue;
            }
            float pmf_secondStage;
            const BDPTVertex& light_subpath =
                reinterpret_cast<Tracer::SubspaceSampler_device*>(&Tracer::params.sampler)->sampleSecondStage(light_id, payload.seed, pmf_secondStage);

            if ((Tracer::visibilityTest(Tracer::params.handle, eye_subpath, light_subpath)))
            { 
                //printf("debug info %f\n", float3weight(tmp_float3));
                float pmf = Tracer::params.sampler.path_count * pmf_secondStage * pmf_firstStage;
                float3 res = connectVertex_SPCBPT(eye_subpath, light_subpath) / pmf;
                if (!ISINVALIDVALUE(res))
                {
                    result += res / CONNECTION_N;
                }
            }
     
        } 
        //printf("%d size error depth%d\n", Tracer::params.lights.count, payload.path.size);
    } 
    
    //env map
    result += payload.result;

    //
    // Update results 
    ////  
    //result = make_float3(rnd(first_hit_id), rnd(first_hit_id), rnd(first_hit_id));  
    const unsigned int image_index = launch_idx.y * launch_dims.x + launch_idx.x;
    float3             accum_color = result;

    if (subframe_index > 0)
    {
        const float  a = 1.0f / static_cast<float>(subframe_index + 1);
        const float3 accum_color_prev = make_float3(Tracer::params.accum_buffer[image_index]);
        accum_color = lerp(accum_color_prev, accum_color, a);
    }
    Tracer::params.accum_buffer[image_index] = make_float4(accum_color, 1.0f);
     
    float4 val = ToneMap(make_float4(accum_color, 0.0), 1.5);
    Tracer::params.frame_buffer[image_index] = make_color(make_float3(val));  
}

RT_FUNCTION float3 eval_path(const BDPTVertex* path, int path_size, int strategy_id)
{
    //return Tracer::contriCompute(path,path_size);
    float pdf = Tracer::pdfCompute(path, path_size, strategy_id);
    float3 contri = Tracer::contriCompute(path, path_size);

    float MIS_weight_not_normalize = Tracer::MISWeight_SPCBPT(path, path_size, strategy_id);
    float MIS_weight_dominator = 0.0;
    for (int i = 2; i <= path_size; i++)
    {
        MIS_weight_dominator += Tracer::MISWeight_SPCBPT(path, path_size, i);
    }

    float3 ans = contri / pdf * (MIS_weight_not_normalize / MIS_weight_dominator);
    if (ISINVALIDVALUE(ans))
    {
        return make_float3(0.0f);
    }
    return ans;
}
extern "C" __global__ void __raygen__SPCBPT_no_rmis()
{
    const uint3  launch_idx = optixGetLaunchIndex();
    const uint3  launch_dims = optixGetLaunchDimensions();
    const float3 eye = Tracer::params.eye;
    const float3 U = Tracer::params.U;
    const float3 V = Tracer::params.V;
    const float3 W = Tracer::params.W;
    const int    subframe_index = Tracer::params.subframe_index;

    float3 normalizeV = normalize(V);
    // Generate camera ray
    //
    unsigned int seed = tea<4>(launch_idx.y * launch_dims.x + launch_idx.x, subframe_index);

    // The center of each pixel is at fraction (0.5,0.5)
    const float2 subpixel_jitter =
        subframe_index == 0 ? make_float2(0.5f, 0.5f) : make_float2(rnd(seed), rnd(seed));

    const float2 d =
        2.0f
        * make_float2((static_cast<float>(launch_idx.x) + subpixel_jitter.x) / static_cast<float>(launch_dims.x),
            (static_cast<float>(launch_idx.y) + subpixel_jitter.y) / static_cast<float>(launch_dims.y))
        - 1.0f;
    float3 ray_direction = normalize(d.x * U + d.y * V + W);
    float3 ray_origin = eye;
    float3 result = make_float3(0);

    Tracer::PayloadBDPTVertex payload;
    payload.clear();
    payload.seed = seed;
    payload.ray_direction = ray_direction;
    payload.origin = ray_origin;
    init_EyeSubpath(payload.path, ray_origin, ray_direction);


#define MAX_PATH_LENGTH_FOR_MIS 20
    BDPTVertex pathBuffer[MAX_PATH_LENGTH_FOR_MIS];
    int buffer_size = 0;
    pathBuffer[buffer_size] = payload.path.currentVertex(); buffer_size++; 

    unsigned first_hit_id;
    while (true)
    {
        ray_direction = payload.ray_direction;
        ray_origin = payload.origin;
        if (payload.done || payload.depth > 50)
        {
            break;
        }
        int begin_depth = payload.path.size;
        Tracer::traceEyeSubPath(Tracer::params.handle, ray_origin, ray_direction,
            SCENE_EPSILON,  // tmin
            1e16f,  // tmax
            &payload);
        if (payload.path.size == begin_depth)
        {
            break;
        } 
        payload.depth += 1;


        pathBuffer[buffer_size] = payload.path.currentVertex(); buffer_size++;
        if (payload.path.hit_lightSource())
        {  
            float3 res = make_float3(0.0);
            Tracer::lightSample light_sample;
            light_sample.ReverseSample(Tracer::params.lights[payload.path.currentVertex().materialId], payload.path.currentVertex().uv);

            BDPTVertex light_vertex;
            init_vertex_from_lightSample(light_sample, light_vertex);
            pathBuffer[buffer_size - 1] = light_vertex;
              
            res = eval_path(pathBuffer,buffer_size,buffer_size);
            result += res; 
            break;
        }
        if (buffer_size >= MAX_PATH_LENGTH_FOR_MIS)break;

        BDPTVertex& eye_subpath = payload.path.currentVertex();
        for (int it = 0; it < CONNECTION_N; it++)
        {

            int light_id = 0;
            float pmf_firstStage = 1;
            if (Tracer::params.subspace_info.light_tree)
            {
                light_id =
                    reinterpret_cast<Tracer::SubspaceSampler_device*>(&Tracer::params.sampler)->sampleFirstStage(eye_subpath.subspaceId, payload.seed, pmf_firstStage);
            }
            if (Tracer::params.sampler.subspace[light_id].size == 0)
            {
                continue;
            }
            float pmf_secondStage;
            const BDPTVertex& light_subpath =
                reinterpret_cast<Tracer::SubspaceSampler_device*>(&Tracer::params.sampler)->sampleSecondStage(light_id, payload.seed, pmf_secondStage);

            if ((buffer_size + light_subpath.depth + 1 <= MAX_PATH_LENGTH_FOR_MIS) &&
                (Tracer::visibilityTest(Tracer::params.handle, eye_subpath.position, light_subpath.position)))
            { 
                float pmf = Tracer::params.sampler.path_count * pmf_secondStage * pmf_firstStage;
                
                int origin_buffer_size = buffer_size;
                const BDPTVertex* light_ptr = &light_subpath;
                while (true)
                {
                    pathBuffer[buffer_size] = *light_ptr; buffer_size++;     
                    if (light_ptr->depth == 0)break;
                    light_ptr--;
                }

                float3 res = eval_path(pathBuffer, buffer_size, origin_buffer_size) / pmf;
                buffer_size = origin_buffer_size;
                
                 
                if (!ISINVALIDVALUE(res))
                {
                    result += res / CONNECTION_N;
                }
            }
        }
        //printf("%d size error depth%d\n", Tracer::params.lights.count, payload.path.size);
    }
    //
    // Update results 
    ////  
    //result = make_float3(rnd(first_hit_id), rnd(first_hit_id), rnd(first_hit_id));  
    const unsigned int image_index = launch_idx.y * launch_dims.x + launch_idx.x;
    float3             accum_color = result;

    if (subframe_index > 0)
    {
        const float  a = 1.0f / static_cast<float>(subframe_index + 1);
        const float3 accum_color_prev = make_float3(Tracer::params.accum_buffer[image_index]);
        accum_color = lerp(accum_color_prev, accum_color, a);
    }
    Tracer::params.accum_buffer[image_index] = make_float4(accum_color, 1.0f);

    float4 val = ToneMap(make_float4(accum_color, 0.0), 1.5);
    Tracer::params.frame_buffer[image_index] = make_color(make_float3(val));
}





#define CheckLightBufferState if(!(lightVertexCount<lt_params.core_padding)) break; 
RT_FUNCTION void pushVertexToLVC(BDPTVertex& v, unsigned int& putId, int bufferBias)
{
    const LightTraceParams& lt_params = Tracer::params.lt;
    lt_params.ans[putId + bufferBias] = v;
    lt_params.validState[putId + bufferBias] = true;
    putId++;
}
extern "C" __global__ void __raygen__lightTrace()
{
    const uint3  launch_idx = optixGetLaunchIndex();
    const uint3  launch_dims = optixGetLaunchDimensions();
    const int    subframe_index = Tracer::params.lt.launch_frame;
    unsigned int seed = tea<4>(launch_idx.y * launch_dims.x + launch_idx.x, subframe_index);

    Tracer::PayloadBDPTVertex payload;
    payload.seed = seed;

    const LightTraceParams& lt_params = Tracer::params.lt;
    int launch_index = launch_idx.x;
    unsigned int bufferBias = lt_params.core_padding * launch_index;
    unsigned int lightVertexCount = 0;
    unsigned int lightPathCount = 0;
     
    while (true)
    {
        payload.clear();
        int light_id = clamp(static_cast<int>(floorf(rnd(seed) * Tracer::params.lights.count)), int(0), int(Tracer::params.lights.count - 1));
        const Light& light = Tracer::params.lights[light_id];
        Tracer::lightSample light_sample; 
        light_sample(light, seed); 


        light_sample.traceMode(seed);
        float3 ray_direction = light_sample.trace_direction();
        float3 ray_origin = light_sample.position; 
        init_lightSubPath_from_lightSample(light_sample, payload.path);
        pushVertexToLVC(payload.path.currentVertex(), lightVertexCount, bufferBias); 
        CheckLightBufferState;

        while (true)
        {
            int begin_depth = payload.path.size;
            Tracer::traceLightSubPath(Tracer::params.handle, ray_origin, ray_direction,
                SCENE_EPSILON,  // tmin
                1e16f,  // tmax
                &payload);
            if (payload.path.size > begin_depth)
            {
                pushVertexToLVC(payload.path.currentVertex(), lightVertexCount, bufferBias); 
                float e = payload.path.currentVertex().contri_float(); 
                CheckLightBufferState;

            }
            ray_direction = payload.ray_direction;
            ray_origin = payload.origin;
            if (payload.done || payload.depth > 50)
            {
                break;
            }
            payload.depth += 1;

        }
        lightPathCount++;
        if (lightPathCount >= lt_params.M_per_core)break;
        CheckLightBufferState; 
    }
    //printf("Light Trace %d get %d path and %d vertices\n", launch_index, lightPathCount, lightVertexCount);
    for (int i = lightVertexCount; i < lt_params.core_padding; i++)
    {
        lt_params.validState[lightVertexCount + bufferBias] = false;
        lightVertexCount++;
    } 
}

extern "C" __global__ void __miss__constant_radiance()
{
    Tracer::PayloadRadiance* prd = Tracer::getPRD();
    prd->done = true;
    prd->currentResult = make_float3(0);
    if (prd->depth == 0&&SKY.valid)
    {
        prd->result = prd->throughput* SKY.color(prd->ray_direction); 
    }
}


extern "C" __global__ void __miss__BDPTVertex()
{
    Tracer::PayloadBDPTVertex* prd = Tracer::getPRD<Tracer::PayloadBDPTVertex>();
    prd->done = true;
//    prd->result = SKY.color(prd->ray_direction);
}



RT_FUNCTION void PreTrace_buildPathInfo(BDPTVertex* eye, TrainData::nVertex_device light, preTracePath* path, preTraceConnection* conn, int pathSize)
{ 
    path->valid = true;
    
    path->begin_ind = 0;
    path->end_ind = pathSize - 1;
    //path->end_ind = 0;
    //return;

    path->sample_pdf = 0;
     
    TrainData::nVertex_device n_eye = TrainData::nVertex_device(*eye, true);

    //printf("material ID %d %d %d\n", n_eye.materialId, eye->materialId, eye->depth);
    TrainData::nVertex_device n_next_eye = TrainData::nVertex_device(light, n_eye, true); 
    float3 seg_contri = n_eye.local_contri(light);

    path->sample_pdf = n_next_eye.pdf; 
    path->sample_pdf += n_eye.pdf * light.pdf;
    path->fix_pdf = n_next_eye.pdf;
    path->contri = eye->flux * light.forward_light(n_eye) * seg_contri;
    for (int i = 0; i < path->end_ind; i++)
    {
        conn[path->end_ind - i - 1] = preTraceConnection(n_eye, light);
        eye--;
        light = TrainData::nVertex_device(n_eye, light, false);
        n_eye = TrainData::nVertex_device(*eye, true);
    }
    float weight = (float3weight(path->contri) / path-> sample_pdf);
    if (isnan(weight))path->contri = make_float3(0);
    if (isinf(weight))path->contri = make_float3(0);
    //printf("pretrace path info%f %f %f\n", float3weight(path->contri), path->fix_pdf, weight);
}
RT_FUNCTION bool rr_acc_accept(int acc_num, unsigned int& seed)
{
    float r = rnd(seed); 
    if (1.0f / (acc_num + 1) > r)
    {
        return true;
    }
    return false;
}
#define PRETRACER_PADDING_VERTICES_CHECK(a) if (a >= pretracer_params.padding)break;
extern "C" __global__ void __raygen__TrainData()
{
    const uint3  launch_idx = optixGetLaunchIndex();
    const uint3  launch_dims = optixGetLaunchDimensions();
    const PreTraceParams& pretracer_params = Tracer::params.pre_tracer;
    const int    subframe_index = pretracer_params.iteration;
    unsigned int seed = tea<4>(launch_idx.y * launch_dims.x + launch_idx.x, subframe_index);


    const float3 eye = Tracer::params.eye;
    const float3 U = Tracer::params.U;
    const float3 V = Tracer::params.V;
    const float3 W = Tracer::params.W; 

    float3 normalizeV = normalize(V);

    const float2 subpixel_jitter = make_float2(rnd(seed), rnd(seed));

    const float2 d = 2.0f * make_float2(subpixel_jitter.x, subpixel_jitter.y) - 1.0f;

    float3 ray_direction = normalize(d.x * U + d.y * V + W);
    float3 ray_origin = eye;
    //printf("eye %f %f %f\n", eye.x, eye.y, eye.z);

    BDPTVertex buffer[PRETRACE_CONN_PADDING];
    int buffer_size = 0;

    int resample_number = 0;
     
    Tracer::PayloadBDPTVertex payload;
    payload.clear();
    payload.seed = seed;
    init_EyeSubpath(payload.path, ray_origin, ray_direction);

    int launch_index = launch_idx.x;
    unsigned int bufferBias = launch_index * pretracer_params.padding;
    preTracePath* currentPath = pretracer_params.paths + launch_index;
    preTraceConnection* currentConn = pretracer_params.conns + bufferBias;
    currentPath->valid = false;
    buffer[buffer_size] = payload.path.currentVertex();
    buffer_size++;

    while (true)
    { 
        int begin_depth = payload.path.size;
        Tracer::traceEyeSubPath(Tracer::params.handle, ray_origin, ray_direction,
            SCENE_EPSILON,  // tmin
            1e16f,  // tmax
            &payload); 
        if (payload.path.size == begin_depth)
        {
            break;
        } 
        if (payload.path.hit_lightSource())
        { 
            if (payload.path.size > 2 && rr_acc_accept(resample_number, payload.seed))
            {
                Tracer::lightSample light_sample;
                int light_id = payload.path.currentVertex().materialId;
                light_sample.ReverseSample(Tracer::params.lights[light_id], payload.path.currentVertex().uv);

                BDPTVertex light_vertex;
                init_vertex_from_lightSample(light_sample, light_vertex);
                PreTrace_buildPathInfo(buffer + buffer_size - 1, TrainData::nVertex_device(light_vertex ,false), currentPath, currentConn, buffer_size);
                resample_number++;
            }  
            break;
        } 
        buffer[buffer_size] = payload.path.currentVertex();
        buffer_size++;

        BDPTVertex& eye_subpath = payload.path.currentVertex();
        Tracer::lightSample light_sample;
        light_sample(payload.seed);
        float3 vis_vec = light_sample.position - eye_subpath.position;
        BDPTVertex light_vertex;
        init_vertex_from_lightSample(light_sample, light_vertex);
        if (Tracer::visibilityTest(Tracer::params.handle, eye_subpath, light_vertex)
            && rr_acc_accept(resample_number, payload.seed)) 
        {
            if ((light_vertex.is_DIRECTION() && dot(light_vertex.normal, eye_subpath.normal) < 0)||
                (!light_vertex.is_DIRECTION() && dot(vis_vec,light_sample.normal())<0))
            {
                PreTrace_buildPathInfo(buffer + buffer_size - 1, TrainData::nVertex_device(light_vertex, false), currentPath, currentConn, buffer_size);
                resample_number++; 
            }
             
        }
         
        if (payload.done || payload.depth > 50)
        {
            break;
        }
        PRETRACER_PADDING_VERTICES_CHECK(buffer_size);
        ray_direction = payload.ray_direction;
        ray_origin = payload.origin;
        payload.depth += 1;
    }

    int beginIndex = 0;
    if (currentPath->valid)
    {
        beginIndex += currentPath->end_ind - currentPath->begin_ind;
    }
    for (int i = beginIndex; i < pretracer_params.padding; i++)
    {
        currentConn[i].valid = false;        
    }
     
    currentPath->sample_pdf/= resample_number;
    currentPath->begin_ind += bufferBias;
    currentPath->end_ind += bufferBias; 
    currentPath->pixel_id = make_int2(Tracer::params.width * subpixel_jitter.x, Tracer::params.height * subpixel_jitter.y);
    if (currentPath->begin_ind == currentPath->end_ind && currentPath->valid == true)
    {
        currentPath->valid = false;
    }
}


RT_FUNCTION bool eye_step(Tracer::PayloadBDPTVertex& prd)
{
    float3 ray_origin = prd.origin;
    float3 ray_direction = prd.ray_direction;
    int origin_depth = prd.path.size;
    Tracer::traceEyeSubPath(Tracer::params.handle, ray_origin, ray_direction,
        SCENE_EPSILON,  // tmin
        1e16f,  // tmax
        &prd);


    prd.depth++;
    if (prd.path.size == origin_depth)
    {
        //miss
        prd.done = true;
        return false;
    }

#define ISLIGHTSOURCE(a) (a.type == HIT_LIGHT_SOURCE||a.type == ENV_MISS)
#define ISVALIDVERTEX(a) (fmaxf(a.flux / a.pdf)>= 0.00000001f)
    if (ISLIGHTSOURCE(prd.path.currentVertex()))
    {
        prd.done = true;
        return true;
    }

    if (!ISVALIDVERTEX(prd.path.currentVertex()))
    {
        prd.done = true;
        return false;
    }
    return true;

}
extern "C" __global__ void __raygen__TrainData_V2()
{
    const uint3  launch_idx = optixGetLaunchIndex();
    const uint3  launch_dims = optixGetLaunchDimensions();
    const PreTraceParams& pretracer_params = Tracer::params.pre_tracer;
    const int    subframe_index = pretracer_params.iteration;
    unsigned int seed = tea<16>(launch_idx.y * launch_dims.x + launch_idx.x, subframe_index);


    const float3 eye = Tracer::params.eye;
    const float3 U = Tracer::params.U;
    const float3 V = Tracer::params.V;
    const float3 W = Tracer::params.W;

    const float2 subpixel_jitter = make_float2(rnd(seed), rnd(seed));

    const float2 d = 2.0f * make_float2(subpixel_jitter.x, subpixel_jitter.y) - 1.0f;
    
    float3 ray_direction = normalize(d.x * U + d.y * V + W);
    float3 ray_origin = eye; 

    BDPTVertex buffer[PRETRACE_CONN_PADDING];
    int buffer_size = 0;

    int resample_number = 0;

    Tracer::PayloadBDPTVertex payload;
    payload.clear();
    payload.seed = seed;
    init_EyeSubpath(payload.path, ray_origin, ray_direction);

    int launch_index = launch_idx.x;
    unsigned int bufferBias = launch_index * pretracer_params.padding;
    preTracePath* currentPath = pretracer_params.paths + launch_index;
    preTraceConnection* currentConn = pretracer_params.conns + bufferBias;
    currentPath->valid = false;

    buffer[buffer_size] = payload.path.currentVertex();
    buffer_size++;
    while (true)
    {
        //bool hit_success = eye_step(payload);
        //if (!hit_success)break;

        //buffer[buffer_size] = payload.path.currentVertex();
        //buffer_size++;
        //PRETRACER_PADDING_VERTICES_CHECK(buffer_size);
        // if(payload.done == true)break;
        //if (!ISLIGHTSOURCE(payload.path.currentVertex()))
        //{
        //    continue;
        //}
        int begin_depth = payload.path.size;
        Tracer::traceEyeSubPath(Tracer::params.handle, ray_origin, ray_direction,
            SCENE_EPSILON,  // tmin
            1e16f,  // tmax
            &payload);
        if (payload.path.size == begin_depth)
        {
            break;
        }
        buffer[buffer_size] = payload.path.currentVertex();
        buffer_size++;
        //if(buffer_size == 1)
        //    printf("pos %f %f %f\n", payload.path.currentVertex().position.x, payload.path.currentVertex().position.y, payload.path.currentVertex().position.z);
        if (payload.path.hit_lightSource())
        { 
            if (payload.path.size > 2)
            {
                int light_id = payload.path.currentVertex().materialId;
                float sample_pdf = payload.path.currentVertex().pdf;
                TrainData::nVertex light_vertex;
                {
                    BDPTVertex eyeEndVertex = payload.path.currentVertex();

                    Tracer::lightSample light_sample;
                    light_sample.ReverseSample(Tracer::params.lights[light_id], payload.path.currentVertex().uv);

                    eyeEndVertex.normal = light_sample.normal();
                    eyeEndVertex.flux = light_sample.emission;
                    eyeEndVertex.pdf = light_sample.pdf; 
                    light_vertex = TrainData::nVertex_device(eyeEndVertex, false);
                    light_vertex.materialId = -1;
                }
                buffer_size--; 
                TrainData::pathInfo_sample& sample = *currentPath;

                sample.valid = true;
                sample.pixel_id = make_int2(Tracer::params.width * subpixel_jitter.x, Tracer::params.height * subpixel_jitter.y);

                TrainData::nVertex_device* light_nVertex_p = (TrainData::nVertex_device*)&light_vertex;
                TrainData::nVertex_device eye_nVertex = TrainData::nVertex_device(buffer[buffer_size - 1], true);
                float3 seg_contri = eye_nVertex.local_contri(*light_nVertex_p);
                sample.contri = buffer[buffer_size - 1].flux * light_nVertex_p->forward_light(eye_nVertex) * seg_contri;
                sample.choice_id = 0;

                if (buffer_size - 1 >= Tracer::params.pre_tracer.padding)
                {
                    sample.valid = false; 
                    break;
                }
                if (!(float3weight(sample.contri) > 0.0))
                {
                    sample.valid = false; 
                    break;
                }
                sample.sample_pdf = sample_pdf;
                sample.fix_pdf = sample_pdf;
                sample.begin_ind = bufferBias;
                int counter = 0;
                {
                    pretracer_params.conns[bufferBias + counter] = TrainData::pathInfo_node(eye_nVertex, *light_nVertex_p);
                    counter++;
                }
                light_nVertex_p = (TrainData::nVertex_device*)&light_vertex;

                eye_nVertex = TrainData::nVertex_device(buffer[buffer_size - 1], true);
                TrainData::nVertex_device light_nVertex; 
                  
                for (int i = 1; buffer_size - 1 - i > 0; i++)
                {
                    light_nVertex = TrainData::nVertex_device(eye_nVertex, *light_nVertex_p, false);

                    eye_nVertex = TrainData::nVertex_device(buffer[buffer_size - 1 - i], true);
                    light_nVertex_p = &light_nVertex;


                    pretracer_params.conns[bufferBias + counter] = TrainData::pathInfo_node(eye_nVertex, *light_nVertex_p);
                    counter++; 
                }
                sample.end_ind = sample.begin_ind + counter; 
                if (sample.fix_pdf < float3weight(sample.contri) * 0.00001)
                {
                    sample.fix_pdf = float3weight(sample.contri) * 0.00001;
                }  
            }
            break;
        }



        if (payload.done )
        {
            break;
        }
        PRETRACER_PADDING_VERTICES_CHECK(buffer_size);
        ray_direction = payload.ray_direction;
        ray_origin = payload.origin;
        payload.depth += 1;
    }

    int beginIndex = 0;
    if (currentPath->valid)
    {
        beginIndex += currentPath->end_ind - currentPath->begin_ind;
    }
    for (int i = beginIndex; i < pretracer_params.padding; i++)
    {
        currentConn[i].valid = false;
    }
     
    currentPath->pixel_id = make_int2(Tracer::params.width * subpixel_jitter.x, Tracer::params.height * subpixel_jitter.y);
    if (currentPath->begin_ind == currentPath->end_ind && currentPath->valid == true)
    { 
        currentPath->valid = false;
    }
}