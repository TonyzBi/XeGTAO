///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Copyright (C) 2016-2021, Intel Corporation 
// 
// SPDX-License-Identifier: MIT
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
// Author(s):  Filip Strugar (filip.strugar@intel.com)
//
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#ifndef VA_RENDER_MESH_HLSL
#define VA_RENDER_MESH_HLSL

#include "vaShared.hlsl"
#include "vaNoise.hlsl"
#include "vaRenderingShared.hlsl"

// This is the "unpacked" vaRenderMesh::StandardVertex
struct RenderMeshVertex
{
    float4 Position             : SV_Position;
    float4 Color                : COLOR;
    float4 Normal               : NORMAL;
    float4 Texcoord01           : TEXCOORD0;
};

// This is the vertex after vertex shading (also used as inputs/outputs for interpolation)
// "SV_Position" was taken out and is used manually on the rasterization side - on the raytracing side it's closest match is dispatchRaysIndex.xy
struct ShadedVertex
{
    float4 Color                : COLOR;            // rarely used in practice - perhaps remove?
    float3 WorldspacePos        : TEXCOORD0;        // this is with the -g_globals.WorldBase offset applied
    float3 WorldspaceNormal     : NORMAL0;
    float4 Texcoord01           : TEXCOORD1;

    float3 ObjectspacePos       : TEXCOORD2;

#ifdef VA_ENABLE_MANUAL_BARYCENTRICS
    float3 Barycentrics         : TEXCOORD3;
#endif
};

struct SurfaceInteraction : ShadedVertex
{
    // mikktspace tangent frame 
    float3  WorldspaceTangent;
    float3  WorldspaceBitangent;

    // non-interpolated, triangle normal
    float3  TriangleNormal;

    // rasterization: normalize(g_globals.CameraWorldPosition.xyz - vertex.WorldspacePos.xyz); raytracing: normalize(-rayDirLength);
    float3  View;
    // length of View above before 'normalize()'
    float   ViewDistance;

    float   NormalVariance;             // du = ddx( worldNormal ); dv = ddy( worldNormal ); dot(du, du) + dot(dv, dv)

    // these are the HIT cone definitions (computed from ray start cone spread angle & widths)
    float   RayConeSpreadAngle;         // spread angle computed at the hit point (enlarged or reduced based on surface curvature) - used as a starting value for the next ray, if any!
    float   RayConeWidth;               // ray cone width computed at the hit point - used as a starting value for the next ray, if any!
    float   RayConeWidthProjected;      // ray cone width computed at the hit point and projected to surface (approximation)

    float   BaseLODWorld;
    float   BaseLODObject;

#ifdef VA_RAYTRACING
    float   BaseLODTex0;
#endif

    // Moved noise to SurfaceInteraction (used to be, and might still be duplicated, in ShadingParams)
    float   ObjectspaceNoise;

    // Is the triangle backface being rendered (or raytraced)
    bool    IsFrontFace;

    // This is the unperturbed tangent space!
    float3x3 TangentToWorld( )
    {
        return float3x3( WorldspaceTangent, WorldspaceBitangent, WorldspaceNormal );
    }

    // not as precise as the DXR WorldRayOrigin()
    float3 RayOrigin( )
    {
        return WorldspacePos + View * ViewDistance;
    }

    void DebugText( )
    {
        ::DebugText( );
        //::DebugText( Position         );
        ::DebugText( Color            );
        ::DebugText( WorldspacePos    );
        ::DebugText( WorldspaceNormal );
        ::DebugText( Texcoord01       );
        ::DebugText( ObjectspacePos   );
        //::DebugText( );
        ::DebugText( float4( WorldspaceTangent , 0 ) );
        ::DebugText( float4( WorldspaceBitangent, 0 ) );
        ::DebugText( float4( TriangleNormal    , 0 ) );
        ::DebugText( float4( View              , 0 ) );
        //::DebugText( );
        ::DebugText( ViewDistance );
        ::DebugText( NormalVariance );
        ::DebugText( float3( RayConeSpreadAngle, RayConeWidth, RayConeWidthProjected ) );
#ifdef VA_RAYTRACING
        ::DebugText( float3( BaseLODWorld, BaseLODObject, BaseLODTex0 ) );
#else
        ::DebugText( float2( BaseLODWorld, BaseLODObject ) );
#endif
        ::DebugText( ObjectspaceNoise );
        ::DebugText( (uint)IsFrontFace );
        ::DebugText( );
    }

    void DebugDrawTangentSpace( float size )
    {
        ::DebugDraw3DArrow( WorldspacePos, WorldspacePos + WorldspaceTangent * size,    size * 0.01, float4( 1, 0, 0, 1 ) );
        ::DebugDraw3DArrow( WorldspacePos, WorldspacePos + WorldspaceBitangent * size,  size * 0.01, float4( 0, 1, 0, 1 ) );
        ::DebugDraw3DArrow( WorldspacePos, WorldspacePos + WorldspaceNormal * size,     size * 0.01, float4( 0, 0, 1, 1 ) );
    }

#ifdef VA_RAYTRACING
    // Raytraced version that interpolates, generates tangent space and front face info, etc.
    static SurfaceInteraction ComputeAtRayHit( const in ShadedVertex a, const in ShadedVertex b, const in ShadedVertex c, float2 barycentrics, float3 rayDirLength, float rayStartConeSpreadAngle, float rayStartConeWidth, uint frontFaceIsClockwise )
#else
    // Non-raytraced version
    static SurfaceInteraction Compute( const in ShadedVertex vertex, const bool isFrontFace )
#endif
    {
        SurfaceInteraction surface;                                                    

#ifdef VA_RAYTRACING
        float3 b3 = float3(1 - barycentrics.x - barycentrics.y, barycentrics.x, barycentrics.y);
        //surface.Position         = b3.x * a.Position         + b3.y * b.Position         + b3.z * c.Position        ;
        surface.Color            = b3.x * a.Color            + b3.y * b.Color            + b3.z * c.Color           ;
        surface.WorldspacePos    = b3.x * a.WorldspacePos    + b3.y * b.WorldspacePos    + b3.z * c.WorldspacePos   ;
        surface.WorldspaceNormal = b3.x * a.WorldspaceNormal + b3.y * b.WorldspaceNormal + b3.z * c.WorldspaceNormal;
        surface.Texcoord01       = b3.x * a.Texcoord01       + b3.y * b.Texcoord01       + b3.z * c.Texcoord01      ;
        surface.ObjectspacePos   = b3.x * a.ObjectspacePos   + b3.y * b.ObjectspacePos   + b3.z * c.ObjectspacePos  ;
        // Proj -> NDC
        // surface.Position.xyz    /= surface.Position.w;
        // surface.Position.xy     = (surface.Position.xy * float2( 0.5, -0.5 ) + float2( 0.5, 0.5 ) ) * g_globals.ViewportSize.xy + 0.5;
#else // !defined(VA_RAYTRACING)
        // surface.Position            = vertex.Position;
        surface.Color               = vertex.Color;
        surface.WorldspacePos       = vertex.WorldspacePos;
        surface.WorldspaceNormal    = vertex.WorldspaceNormal;
        surface.Texcoord01          = vertex.Texcoord01;
        surface.ObjectspacePos      = vertex.ObjectspacePos;
        surface.IsFrontFace         = isFrontFace;
        float rayStartConeSpreadAngle   = g_globals.PixelFOVXY.x;
        float rayStartConeWidth         = 0; // always 0 for primary rays!
#endif
        // interpolated normal needs normalizing!
        surface.WorldspaceNormal.xyz = normalize( surface.WorldspaceNormal.xyz );

        // used below
#ifdef VA_RAYTRACING
        float3 objDDX   = b.ObjectspacePos.xyz-a.ObjectspacePos.xyz;
        float3 objDDY   = c.ObjectspacePos.xyz-a.ObjectspacePos.xyz;
#else
        float3 objDDX   = ddx_fine( surface.ObjectspacePos.xyz );
        float3 objDDY   = ddy_fine( surface.ObjectspacePos.xyz );
#endif
        // we'll need this below
#ifdef VA_RAYTRACING
        surface.View            = -rayDirLength;        // view vector is just -ray, right?
#else
        surface.View            = g_globals.CameraWorldPosition.xyz - surface.WorldspacePos.xyz;
#endif
        surface.ViewDistance    = length( surface.View );
        surface.View            = surface.View / surface.ViewDistance;

        ///************************ COMPUTE TANGENT SPACE ************************
        // See GenBasisTB() in vaRenderingShared.hlsl - this one has been hacked to work for raytracing too; seems to be ok?
        const float3 nrmBaseNormal = surface.WorldspaceNormal.xyz;   // just matching the naming convention
#ifdef VA_RAYTRACING
        float3 dPdx = b.WorldspacePos.xyz-a.WorldspacePos.xyz;
        float3 dPdy = c.WorldspacePos.xyz-a.WorldspacePos.xyz;
#else
        float3 dPdx = ddx_fine( surface.WorldspacePos.xyz );
        float3 dPdy = ddy_fine( surface.WorldspacePos.xyz );
#endif
        float3 sigmaX = dPdx - dot ( dPdx, nrmBaseNormal ) * nrmBaseNormal;
        float3 sigmaY = dPdy - dot ( dPdy, nrmBaseNormal ) * nrmBaseNormal;
        float flip_sign = dot ( dPdy , cross ( nrmBaseNormal , dPdx )) <0 ? -1 : 1;
#ifdef VA_RAYTRACING
        float2 dSTdx = b.Texcoord01.xy-a.Texcoord01.xy;     // these are not the same as ddx/ddy below but math works out
        float2 dSTdy = c.Texcoord01.xy-a.Texcoord01.xy;     // these are not the same as ddx/ddy below but math works out
#else
        float2 dSTdx = ddx_fine( surface.Texcoord01.xy );
        float2 dSTdy = ddy_fine( surface.Texcoord01.xy );
#endif

        float3 vT; float3 vB;
        float det = dot ( dSTdx , float2 ( dSTdy.y , -dSTdy.x ) );
        float sign_det = det <0 ? -1 : 1;
        // invC0 represents ( dXds , dYds ) ; but we don �t divide by
        // determinant ( scale by sign instead )
        float2 invC0 = sign_det * float2 ( dSTdy .y , - dSTdx .y );
        vT = sigmaX * invC0.x + sigmaY * invC0 .y;
        float lengthT = length(vT);
        // if( abs ( det ) > 0.0) vT = normalize ( vT ) ;
        if( lengthT > 1e-10 )
        {
            vT /= lengthT;
            vB = ( sign_det * flip_sign ) * cross ( nrmBaseNormal , vT );
            surface.WorldspaceTangent       = vT;
            surface.WorldspaceBitangent     = vB;
        }
        else // sometimes UVs are just broken, so this is a fallback <shrug>
            ComputeOrthonormalBasis( nrmBaseNormal, surface.WorldspaceTangent, surface.WorldspaceBitangent );
        ///***********************************************************************

        ///*********************** COMPUTE TRIANGLE NORMAL ***********************
        // If we're rasterizing back face or the ray is hitting back face, by
        // convention we invert the normal (but keep the IsFrontFace flag in case
        // this information is later needed)
        surface.TriangleNormal      = normalize( cross( dPdx, dPdy ) );
        // surface.TriangleNormal      = normalize( (frontFaceIsClockwise)?(cross( dPdx, dPdy )):(cross( dPdy, dPdx ) ) );
#ifdef VA_RAYTRACING
        surface.IsFrontFace         = dot( surface.TriangleNormal, rayDirLength ) < 0;
        // surface.IsFrontFace         = (frontFaceIsClockwise)?(surface.IsFrontFace):(-surface.IsFrontFace);  // I'm <really> not sure what to do about this bit
#else
        surface.IsFrontFace         = isFrontFace;
#endif
        float frontFaceSign = (surface.IsFrontFace)?(1.0):(-1.0);
        surface.TriangleNormal      *= frontFaceSign;
        surface.WorldspaceNormal    *= frontFaceSign;
        //        float frontFaceSign = (surface.IsFrontFace)?(1.0):(-1.0);
        ///***********************************************************************


        ///***************** COMPUTE RAY CONE PARAMS AT HIT POINT ****************
        //
        // see RaytracingGems 1, Figure 20-6 illustrates the surface spread angle [beta], which will be zero for planar reflections, greater than zero for convex 
        // reflections, and less than zero for concave reflections.
        float betaAngle             = 0.0; // TODO: do this properly: see 20.3.4.4 SURFACE SPREAD ANGLE FOR REFLECTIONS
        //
        // see w0 in chapter 20.3.4.1, approx of "2 * rayLength * tan( ConeSpreadAngle / 2 )"
        // see see RaytracingGems 1, Equation 29
        surface.RayConeWidth            = rayStartConeWidth + surface.ViewDistance * (rayStartConeSpreadAngle + betaAngle);       // note: surface.ViewDistance is rayLength!
        surface.RayConeSpreadAngle      = rayStartConeSpreadAngle + betaAngle;
        //
        // see RayTracingGems 1, chapter 20.3.4.1, equation 25; added is the slope modifier 
        const float cMIPSlopeModifier = 0.45; // <- this is a customization; baked in here; it tweaks MIP selection to appear more like anisotropic (while it's just trilinear)
        surface.RayConeWidthProjected   = surface.RayConeWidth / pow( abs( dot( surface.TriangleNormal, surface.View ) ), cMIPSlopeModifier );
        ///***********************************************************************

        ///********************* COMPUTE VARIOUS MIP OFFSETS *********************
        // see RayTracingGems 1, chapter 20.3.4.1
        //float rayLength         = length(rayDirLength);
        //float3 rayDir           = rayDirLength / rayLength;
        //surface.RayConeWidth        = rayLength * rayStartConeSpreadAngle; // see w0 in chapter 20.3.4.1, approx of "2 * rayLength * tan( ConeSpreadAngle / 2 )"

        surface.BaseLODWorld    = log2( surface.RayConeWidthProjected );

#ifdef VA_RAYTRACING
        // see RayTracingGems 1, chapter 20.2, Equation 3 - except we leave out texture resolution here
        float2 dTex0_AC         = b.Texcoord01.xy-a.Texcoord01.xy;
        float2 dTex0_BC         = c.Texcoord01.xy-a.Texcoord01.xy;
        float triWorldAreaX2    = length( cross( dPdx, dPdy ) );
        float triTex0AreaX2     = abs( dTex0_AC.x * dTex0_BC.y - dTex0_BC.x * dTex0_AC.y );
        float baseLODTex0       = log2( sqrt(triTex0AreaX2 / triWorldAreaX2) ); // same as Delta from Equation 3, except texture solution left out
        surface.BaseLODTex0         = baseLODTex0 + surface.BaseLODWorld + g_globals.RaytracingMIPOffset;
#else
        float triWorldAreaX2    = length( cross( dPdx, dPdy ) );    // <- not actual triWorldAreaX2!! just area over a pixel (since inputs are ddx/ddy)
#endif

        float triObjAreaX2      = length( cross( objDDX, objDDY ) );  // <- not actual triObjAreaX2!! just area over a pixel (since inputs are ddx/ddy)
        float baseLODObject     = log2( sqrt(triObjAreaX2 / triWorldAreaX2) ); // same as Delta from Equation 3, except texture solution left out
        surface.BaseLODObject       = baseLODObject + surface.BaseLODWorld;
        ///***********************************************************************

        ///******************************** NOISE ********************************
        Noise3D( surface.ObjectspacePos.xyz, surface.BaseLODObject, surface.RayConeWidth, surface.RayConeWidthProjected, surface.ObjectspaceNoise );
        ///***********************************************************************

        ///********************* GEOMETRIC NORMAL VARIANCE ***********************
#ifdef VA_RAYTRACING
        float3 normDDX  = (b.WorldspaceNormal.xyz-a.WorldspaceNormal.xyz); // <- do this scaling for raytracing during camera ray setup on ray cone spread angle 
        float3 normDDY  = (c.WorldspaceNormal.xyz-a.WorldspaceNormal.xyz); // <- do this scaling for raytracing during camera ray setup on ray cone spread angle 
        surface.NormalVariance = length( cross( normDDX, normDDY ) ) / triWorldAreaX2 * surface.RayConeWidth * surface.RayConeWidth;
#else
        float3 normDDX  = ddx_fine( surface.WorldspaceNormal.xyz );
        float3 normDDY  = ddy_fine( surface.WorldspaceNormal.xyz );
        // surface.NormalVariance = (dot(normDDX, normDDX) + dot(normDDY, normDDY));   // < listing 2, http://www.jp.square-enix.com/tech/library/pdf/ImprovedGeometricSpecularAA.pdf
        surface.NormalVariance = length( cross( normDDX, normDDY ) );   // my hack until I figure how to unify raytrace and raster paths here :(
#endif
        surface.NormalVariance *= g_globals.GlobalSpecularAAScale * g_globals.GlobalSpecularAAScale;
        ///***********************************************************************


        return surface;
    }
};

RenderMeshVertex RenderMeshManualVertexLoad( const uint vertexBufferBindlessIndex, const uint index )
{
    const uint SizeOfStandardVertex = 48;
    RenderMeshVertex ret;

    const uint baseAddress = index * SizeOfStandardVertex;
    uint4 poscolRaw = g_bindlessBAB[vertexBufferBindlessIndex].Load4( baseAddress + 0 );
    ret.Position    = float4( asfloat( poscolRaw.xyz ), 1 );
    ret.Color       = R8G8B8A8_UNORM_to_FLOAT4( poscolRaw.w );
    ret.Normal      = asfloat( g_bindlessBAB[vertexBufferBindlessIndex].Load4( baseAddress + 16 ) );
    ret.Texcoord01  = asfloat( g_bindlessBAB[vertexBufferBindlessIndex].Load4( baseAddress + 32 ) );

    return ret;
}

ShadedVertex RenderMeshVertexShader( const RenderMeshVertex input, const ShaderInstanceConstants instanceConstants )
{
    ShadedVertex ret;

    ret.ObjectspacePos      = input.Position.xyz;

    //ret.Color                   = input.Color;
    ret.Texcoord01          = input.Texcoord01;
    // ret.Texcoord23          = float4( 0, 0, 0, 0 );

    ret.WorldspacePos.xyz    = mul( instanceConstants.World, float4( input.Position.xyz, 1 ) );
    ret.WorldspaceNormal.xyz = normalize( mul( (float3x3)instanceConstants.NormalWorld, input.Normal.xyz ).xyz );

    // do all the subsequent shading math with the WorldBase for precision purposes
    ret.WorldspacePos.xyz -= g_globals.WorldBase.xyz;

    // hijack this for highlighting and similar stuff
    ret.Color               = input.Color;

#ifdef VA_ENABLE_MANUAL_BARYCENTRICS
    ret.Barycentrics        = float3( 0, 0, 0 );
#endif

    return ret;
}

#ifndef VA_RAYTRACING

#if 0 // this version manually reads vertices instead of using vertex fixed function pipeline via the layouts - for testing only, it's slower
ShadedVertex VS_Standard( uint vertID : SV_VertexID )
{
    const ShaderInstanceConstants instanceConstants = LoadInstanceConstants( g_instanceIndex.InstanceIndex );
    const ShaderMeshConstants meshConstants         = g_meshConstants[instanceConstants.MeshGlobalIndex];
    return RenderMeshVertexShader( RenderMeshManualVertexLoad( meshConstants.VertexBufferBindlessIndex, vertID ), instanceConstants );
}
#else
ShadedVertex VS_Standard( const in RenderMeshVertex input, uint vertID : SV_VertexID, out float4 position : SV_Position )
{
    ShadedVertex a = RenderMeshVertexShader( input, LoadInstanceConstants( g_instanceIndex.InstanceIndex ) );

#if 1   // default (fastest) path
    position = mul( g_globals.ViewProj, float4( a.WorldspacePos.xyz, 1.0 ) );
    return a;
#else // test the standard vertex shader inputs vs the manual vertex inputs
    const ShaderInstanceConstants instanceConstants = LoadInstanceConstants( g_instanceIndex.InstanceIndex );
    const ShaderMeshConstants meshConstants         = g_meshConstants[instanceConstants.MeshGlobalIndex];
    ShadedVertex b = RenderMeshVertexShader( RenderMeshManualVertexLoad( meshConstants.VertexBufferBindlessIndex, vertID ), instanceConstants );

    // // just show a line up from every 0-th vertex 
    // [branch] if( vertID == 0 )
    //     DebugDraw3DLine( b.WorldspacePos.xyz, b.WorldspacePos.xyz + float3( 0, 0, 1 ), float4( 0.5, 5.0, 0.5, 0.9 ) );
   
    //a.Color.a += 0.0001;
    if( any( a.Position != b.Position ) ||
        any( a.Color            != b.Color            ) ||
        any( a.WorldspacePos    != b.WorldspacePos    ) ||
        any( a.WorldspaceNormal != b.WorldspaceNormal ) ||
        any( a.Texcoord01       != b.Texcoord01       ) )
        b.Color.x = 0;

    position = mul( g_globals.ViewProj, float4( b.WorldspacePos.xyz, 1.0 ) );
    return b;
#endif
}
#endif

#if defined(VA_ENABLE_MANUAL_BARYCENTRICS) && !defined(VA_ENABLE_PASSTHROUGH_GS)
#error manual barycentrics require custom GS below
#endif

#ifdef VA_ENABLE_PASSTHROUGH_GS

// // Per-vertex data passed to the rasterizer.
// struct GeometryShaderOutput
// {
//     min16float4 pos     : SV_POSITION;
//     min16float3 color   : COLOR0;
//     uint        rtvId   : SV_RenderTargetArrayIndex;
// };


// This geometry shader is a pass-through that leaves the geometry unmodified 
// and sets the render target array index.
[maxvertexcount(3)]
void GS_Standard(triangle ShadedVertex input[3], inout TriangleStream<ShadedVertex> outStream) <- this needs reworking w.r.t. sv_position, perhaps a new struct
{
    ShadedVertex output;
    [unroll(3)]
    for (int i = 0; i < 3; ++i)
    {
        output.Position        = input[i].Position;
        output.Color           = input[i].Color;
        output.WorldspacePos   = input[i].WorldspacePos;
        output.WorldspaceNormal= input[i].WorldspaceNormal;
        output.Texcoord01      = input[i].Texcoord01;

        output.ObjectspacePos  = input[i].ObjectspacePos;

#ifdef VA_ENABLE_MANUAL_BARYCENTRICS
        output.Barycentrics     = float3( i==0, i==1, i==2 );
#endif

        outStream.Append(output);
    }
}

#endif // VA_ENABLE_PASSTHROUGH_GS

#endif // VA_RAYTRACING

#endif // VA_RENDER_MESH_HLSL