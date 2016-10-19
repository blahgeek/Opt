#pragma once

#define OPT_DOUBLE_PRECISION 0

#if OPT_DOUBLE_PRECISION
#   define OPT_FLOAT double
#   define OPT_FLOAT2 double2
#   define OPT_FLOAT3 double3
#   define OPT_FLOAT4 double4
#else
#   define OPT_FLOAT float
#   define OPT_FLOAT2 float2
#   define OPT_FLOAT3 float3
#   define OPT_FLOAT4 float4
#endif