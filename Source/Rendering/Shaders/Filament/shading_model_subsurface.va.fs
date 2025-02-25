/**
 * Evalutes lit materials with the subsurface shading model. This model is a
 * combination of a BRDF (the same used in shading_model_standard.fs, refer to that
 * file for more information) and of an approximated BTDF to simulate subsurface
 * scattering. The BTDF itself is not physically based and does not represent a
 * correct interpretation of transmission events.
 */
void surfaceShading( const ShadingParams shading, const PixelParams pixel, const LightParams light, float occlusion, inout float3 inoutColor ) 
{
    vec3 h = normalize(shading.View + light.L);

    float NoL = light.NoL;
    float NoH = saturate( dot( shading.Normal, h ));
    float LoH = saturate( dot( light.L, h ) );

    vec3 Fr = 0.0.xxx;
    if (NoL > 0.0) 
    {
        // specular BRDF
        float D = distribution(pixel.Roughness, NoH, h);
        float V = visibility(pixel.Roughness, shading.NoV, NoL);
        vec3  F = fresnel(pixel.F0, LoH);
        Fr = (D * V) * F * pixel.EnergyCompensation;
    }

    // diffuse BRDF
    vec3 Fd = pixel.DiffuseColor * diffuse(pixel.Roughness, shading.NoV, NoL, LoH);

    // NoL does not apply to transmitted light
    //vec3 color = (Fd + Fr) * (NoL * occlusion);
    float3 diffuseColor    = (Fd) * (NoL * occlusion);
    float3 specularColor   = (Fr) * (NoL * occlusion);

    // subsurface scattering
    // Use a spherical gaussian approximation of pow() for forwardScattering
    // We could include distortion by adding shading_normal * distortion to light.l
    float scatterVoH = saturate(dot(shading.View, -light.L));
    float forwardScatter = exp2(scatterVoH * pixel.SubsurfacePower - pixel.SubsurfacePower);
    float backScatter = saturate(NoL * pixel.Thickness + (1.0 - pixel.Thickness)) * 0.5;
    float subsurface = mix(backScatter, 1.0, forwardScatter) * (1.0 - pixel.Thickness);
    diffuseColor += pixel.SubsurfaceColor * (subsurface * Fd_Lambert());

    // TODO: apply occlusion to the transmitted light
    // color = (color * light.ColorIntensity.rgb) * (light.ColorIntensity.w * light.Attenuation);
    float3 lightColor = light.ColorIntensity.rgb * (light.ColorIntensity.w * light.Attenuation);
    inoutColor  += (diffuseColor+specularColor) * lightColor;
}
