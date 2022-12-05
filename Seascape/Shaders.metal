//
//  Shaders.metal
//  Seascape
//
/*
 * "Seascape" by Alexander Alekseev aka TDM - 2014
 * License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.
 * Contact: tdmaav@gmail.com
 */
//
//  Original code available at: https://www.shadertoy.com/view/Ms2SD1
//
//  Created by João Varela on 05/08/2018.
//  Adaptation to Metal by João Varela, 2018 - Same license as above
//

// File for Metal kernel and shader functions

#include <metal_stdlib>
#include <simd/simd.h>

// Including header shared between this Metal shader code and Swift/C code executing Metal API commands
#import "ShaderTypes.h"

using namespace metal;

constant int NUM_STEPS  = 8;
constant float PI       = 3.141592;
// #define EPSILON_NRM (0.1 / iResolution.x)

// sea
constant int ITER_GEOMETRY      = 3;
constant int ITER_FRAGMENT      = 5;
constant float SEA_HEIGHT       = 0.6;
constant float SEA_CHOPPY       = 4.0;
constant float SEA_SPEED        = 0.8;
constant float SEA_FREQ         = 0.16;
constant float3 SEA_BASE        = float3(.1,.19,.22);
constant float3 SEA_WATER_COLOR = float3(.8,.9,.6);
constant float2x2 octave_m      = float2x2(1.6,1.2,-1.2,1.6);

// #define SEA_TIME (1.0 + iTime * SEA_SPEED)
float seaTime(float time) {
    return 1. + time * SEA_SPEED;
}

// math
float3x3 fromEuler(float3 ang) {
    float2 a1 = float2(sin(ang.x),cos(ang.x));
    float2 a2 = float2(sin(ang.y),cos(ang.y));
    float2 a3 = float2(sin(ang.z),cos(ang.z));
    float3 m0 = float3(a1.y*a3.y+a1.x*a2.x*a3.x,a1.y*a2.x*a3.x+a3.y*a1.x,-a2.y*a3.x);
    float3 m1 = float3(-a2.y*a1.x,a1.y*a2.y,a2.x);
    float3 m2 = float3(a3.y*a1.x*a2.x+a1.y*a3.x,a1.x*a3.x-a1.y*a3.y*a2.x,a2.y*a3.y);
    float3x3 m = float3x3(m0,m1,m2);
    return m;
}

float hash(float2 p) {
    float h = dot(p,float2(127.1,311.7));
    return fract(sin(h)*43758.5453123);
}

float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f*f*(3.0-2.0*f);
    return -1.0+2.0*mix(mix(hash(i + float2(0.,0.) ),
                            hash(i + float2(1.,0.) ), u.x),
                        mix(hash(i + float2(0.,1.) ),
                            hash(i + float2(1.,1.) ), u.x), u.y);
}

// lighting
float diffuse(float3 n,float3 l,float p) {
    return pow(dot(n,l) * .4 + .6,p);
}
float specular(float3 n,float3 l,float3 e,float s) {
    float nrm = (s + 8.0) / (PI * 8.0);
    return pow(max(dot(reflect(e,n),l),0.0),s) * nrm;
}

// sky
float3 getSkyColor(float3 e) {
    e.y = max(e.y,0.0);
    return float3(pow(1.0-e.y,2.0), 1.0-e.y, 0.6+(1.0-e.y)*0.4);
}

// sea
float sea_octave(float2 uv, float choppy) {
    uv += noise(uv);
    float2 wv = 1.0-abs(sin(uv));
    float2 swv = abs(cos(uv));
    wv = mix(wv,swv,wv);
    return pow(1.0-pow(wv.x * wv.y,0.65),choppy);
}

float map(float3 p, float time) {
    float freq = SEA_FREQ;
    float amp = SEA_HEIGHT;
    float choppy = SEA_CHOPPY;
    float sea_time = seaTime(time);
    float2 uv = p.xz; uv.x *= 0.75;
    
    float d, h = 0.0;
    for(int i = 0; i < ITER_GEOMETRY; i++) {
        d = sea_octave((uv+sea_time)*freq,choppy);
        d += sea_octave((uv-sea_time)*freq,choppy);
        h += d * amp;
        uv *= octave_m; freq *= 1.9; amp *= 0.22;
        choppy = mix(choppy,1.0,0.2);
    }
    return p.y - h;
}

float map_detailed(float3 p, float time) {
    float freq = SEA_FREQ;
    float amp = SEA_HEIGHT;
    float choppy = SEA_CHOPPY;
    float sea_time = seaTime(time);
    float2 uv = p.xz; uv.x *= 0.75;
    
    float d, h = 0.0;
    for(int i = 0; i < ITER_FRAGMENT; i++) {
        d = sea_octave((uv+sea_time)*freq,choppy);
        d += sea_octave((uv-sea_time)*freq,choppy);
        h += d * amp;
        uv *= octave_m; freq *= 1.9; amp *= 0.22;
        choppy = mix(choppy,1.0,0.2);
    }
    return p.y - h;
}

float3 getSeaColor(float3 p, float3 n, float3 l, float3 eye, float3 dist) {
    float fresnel = clamp(1.0 - dot(n,-eye), 0.0, 1.0);
    fresnel = pow(fresnel,3.0) * 0.65;
    float3 reflected = getSkyColor(reflect(eye,n));
    float3 refracted = SEA_BASE + diffuse(n,l,80.0) * SEA_WATER_COLOR * 0.12;
    float3 color = mix(refracted,reflected,fresnel);
    float atten = max(1.0 - dot(dist,dist) * 0.001, 0.0);
    color += SEA_WATER_COLOR * (p.y - SEA_HEIGHT) * 0.18 * atten;
    color += float3(specular(n,l,eye,60.0));
    return color;
}

// tracing
float3 getNormal(float3 p, float eps, float time) {
    float3 n;
    n.y = map_detailed(p,time);
    n.x = map_detailed(float3(p.x+eps,p.y,p.z),time) - n.y;
    n.z = map_detailed(float3(p.x,p.y,p.z+eps),time) - n.y;
    n.y = eps;
    return normalize(n);
}

float3 heightMapTracing(float3 ori, float3 dir, float time) {
    float tm = 0.;
    float tx = 1000.;
    float hx = map(ori + dir * tx, time);
    if(hx > 0.) return tx;
    float hm = map(ori + dir * tm, time);
    float tmid = 0.;
    float3 p = float3(0.);
    for(int i = 0; i < NUM_STEPS; i++) {
        tmid = mix(tm,tx, hm/(hm-hx));
        p = ori + dir * tmid;
        float hmid = map(p,time);
        if(hmid < 0.) {
            tx = tmid;
            hx = hmid;
        } else {
            tm = tmid;
            hm = hmid;
        }
    }
    return p;
}

kernel void compute(texture2d<float,access::write> output [[texture(0)]],
                    constant float4 &input [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]])
{
    // Set Metal input variables -- begin
    // get the width and height of the screen texture
    int width = output.get_width();
    int height = output.get_height();
    
    // set its resolution
    float2 iResolution = float2(width, height);
    
    // compute the texture coordinates with the y-coordinate flipped
    // because the origin of Shadertoy's and Metal's y-coordinates differ
    float2 uv = float2(gid.x,height - gid.y) / iResolution;
    
    // normalized mouse input
    float2 iMouse = input.xy / iResolution;
    
    // get time
    float iTime = input.w;
    
    // Seascape custom code -- begin
    uv = uv * 2. - 1.;
    uv.x *= iResolution.x/iResolution.y;
    float time = iTime * .3 + iMouse.x * .2;
    
    // ray
    float3 ang = float3(sin(time*3.)*.1,sin(time)*.2+.3,time);
    float3 ori = float3(0.,3.5,time*5.);
    float3 dir = normalize(float3(uv.xy,-2.)); dir.z += length(uv) * .15;
    dir = normalize(dir) * fromEuler(ang);
    
    // tracing
    float3 p = heightMapTracing(ori,dir,iTime);
    float3 dist = p - ori;
    float3 n = getNormal(p, dot(dist,dist) * (.1/iResolution.x),iTime);
    float3 light = normalize(float3(0.,1.,.8));
    
    // color
    float3 color = mix(getSkyColor(dir),
                       getSeaColor(p,n,light,dir,dist),
                       pow(smoothstep(0.,-.05,dir.y),.3));
    
    // post
    output.write(float4(pow(color,float3(.75)), 1.), gid);
}
