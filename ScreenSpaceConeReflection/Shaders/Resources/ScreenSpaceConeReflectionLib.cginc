	/*The MIT License (MIT)

	Copyright (c) 2016 Charles Greivelding Thomas

	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.*/
	
	#define PI 3.14159265359
	#define MAX_BLUR_SAMPLE 32
	#define MAX_MIP_MAP 11
	#define MIP_MAP_TEXTURE_SIZE 1024

	#include "UnityCG.cginc"
	#include "UnityStandardBRDF.cginc"

	uniform sampler2D	_MainTex,
						_ReflectionBuffer,
						_RayCast;

	uniform sampler2D	_CameraGBufferTexture0; // Diffuse RGB and Occlusion A
	uniform sampler2D	_CameraGBufferTexture1; // Specular RGB and Roughness/Smoothness A
	uniform sampler2D	_CameraGBufferTexture2; // World Normal RGB
	uniform sampler2D	_CameraReflectionsTexture; // Cubemap reflection 
	uniform sampler2D	_CameraDepthTexture;

	uniform float		_EdgeFactor; 
	uniform float		_SmoothnessRange;
	uniform float		_MipMapExponent;

	uniform int			_NumSteps;
	uniform int			_TemporalNoise;

	uniform float4x4	_ProjectionMatrix;
	uniform float4x4	_InverseProjectionMatrix;
	uniform float4x4	_InverseViewProjectionMatrix;
	uniform float4x4	_WorldToCameraMatrix;

	//Debug
	uniform int			_DebugPass;

	float sqr(float x) 
	{ 
		return x*x; 
	}
	
	float4 GetCubeMap (float2 uv) { return tex2D(_CameraReflectionsTexture, uv); }
	float4 GetAlbedo (float2 uv) { return tex2D(_CameraGBufferTexture0, uv); }
	float4 GetSpecular (float2 uv) { return tex2D(_CameraGBufferTexture1, uv); }
	float GetRoughness (float smoothness) { return max(min(_SmoothnessRange, 1 - smoothness), 0.05f); }
	float4 GetNormal (float2 uv) { return tex2D(_CameraGBufferTexture2, uv) * 2.0 - 1.0; }
	float4 GetReflection(float2 uv)    { return tex2D(_ReflectionBuffer, uv); }
	float4 GetSceneColor(float2 uv)    { return tex2D(_MainTex, uv); }

	float3 GetViewNormal (float3 normal)
	{
		float3 viewNormal =  mul((float3x3)_WorldToCameraMatrix, normal.rgb);
		return normalize(viewNormal);
	}
	
	float GetDepth (float2 uv)
	{
		return SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);
	}

	float3 GetScreenPos (float2 uv, float depth)
	{
		return float3(uv * 2 - 1, depth);
	}

	float3 GetWorlPos (float3 clipPosition)
	{
		float4 worldPos = mul(_InverseViewProjectionMatrix, float4(clipPosition, 1));
		return worldPos.xyz / worldPos.w;
	}

	float3 GetViewPos (float3 clipPosition)
	{
		float4 viewPos = mul(_InverseProjectionMatrix, float4(clipPosition, 1));
		return viewPos.xyz / viewPos.w;
	}
	
	float3 GetViewDir (float3 worldPos)
	{
		return normalize(worldPos - _WorldSpaceCameraPos);
	}

	// [ Lazarov 2013, "Getting More Physical in Call of Duty: Black Ops II" ]
	// Changed by EPIC
	float3 F_LazarovApprox(float3 SpecularColor, float Roughness, float NdotV)
	{
		const float4 c0 = { -1, -0.0275, -0.572, 0.022 };
		const float4 c1 = { 1, 0.0425, 1.04, -0.04 };
		float4 r = Roughness * c0 + c1;
		float a004 = min( r.x * r.x, exp2( -9.28 * NdotV ) ) * r.x + r.y;
		float2 AB = float2( -1.04, 1.04 ) * a004 + r.zw;

		return SpecularColor * AB.x + AB.y;
	}

	float4 RayMarch(float3 R,int NumSteps, float3 viewPos, float3 screenPos, float2 coord, float stepOffset)
	{

		float4 rayPos = float4(viewPos + R, 1);
		float4 rayUV = mul (_ProjectionMatrix, rayPos);
		rayUV.xyz /= rayUV.w;
					
		float3 rayDir = normalize( rayUV - screenPos );
		rayDir.xy *= 0.5;

		float sampleDepth;
		float sampleMask = 0;

	    float3 rayStart = float3(coord,screenPos.z);
                    
 		float stepSize = 1 / ( (float)NumSteps + 1);
		rayDir  *= stepOffset * stepSize + stepSize;
                                  
		float3 samplePos = rayStart + rayDir;

		for (int steps = 1;  steps < NumSteps; ++steps)
		{
			sampleDepth  = (UNITY_SAMPLE_DEPTH(tex2Dlod (_CameraDepthTexture, float4(samplePos.xy,0,0))));
 
			if ( sampleDepth < (samplePos.z) )  
			{  
				if (abs(sampleDepth - (samplePos.z)))
				{
					sampleMask = 1;
					break;
				}
				else
				{
					rayDir *= 0.5;
					samplePos = rayStart + rayDir; 
				} 	                
			}
			else
			{
		        rayStart = samplePos;
		        samplePos += rayDir;
			}
		}

		return float4(samplePos.xy, sampleMask, 1.0f);

	}
	
	float4 TangentToWorld(float3 N, float4 H)
	{
		float3 UpVector = abs(N.z) < 0.999 ? float3(0,0,1) : float3(1,0,0);
		float3 T = normalize( cross( UpVector, N ) );
		float3 B = cross( N, T );
				 
		return float4((T * H.x) + (B * H.y) + (N * H.z), H.w);
	}

	float4 ImportanceSampleBlinn( float2 Xi, float Roughness )
	{
		float m = Roughness*Roughness;
		float m2 = m*m;
		
		float n = 2 / m2 - 2;

		float Phi = 2 * PI * Xi.x;
		float CosTheta = pow( max(Xi.y, 0.001f), 1 / (n + 1) );
		float SinTheta = sqrt( 1 - CosTheta * CosTheta );

		float3 H;
		H.x = SinTheta * cos( Phi );
		H.y = SinTheta * sin( Phi );
		H.z = CosTheta;
		
		float D = (n+2)/ (2*PI) * saturate(pow( CosTheta, n ));
		float pdf = D * CosTheta;

		return float4(H, pdf); 
	}
		
	// Brian Karis, Epic Games "Real Shading in Unreal Engine 4"
	float4 ImportanceSampleGGX( float2 Xi, float Roughness )
	{
		float m = Roughness*Roughness;
		float m2 = m*m;
		
		float Phi = 2 * PI * Xi.x;
				 
		float CosTheta = sqrt( (1 - Xi.y) / ( 1 + (m2 - 1) * Xi.y ) );
		float SinTheta = sqrt( 1 - CosTheta * CosTheta );  
				 
		float3 H;
		H.x = SinTheta * cos( Phi );
		H.y = SinTheta * sin( Phi );
		H.z = CosTheta;
		
		float d = ( CosTheta * m2 - CosTheta ) * CosTheta + 1;
		float D = m2 / ( PI*d*d );
		float pdf = D * CosTheta;

		return float4(H, pdf); 
	}

	float2 Noise(float2 pos, float random)
	{
    	return frac(sin(dot(pos.xy * random, float2(12.9898f, 78.233f))) * float2(43758.5453f, 28001.8384f));
	}

	// https://en.wikipedia.org/wiki/Halton_sequence
	float HaltonSequence (uint index, uint base = 3)
	{
		float result = 0;
		float f = 1;
		int i = index;
		while (i > 0) 
		{
			f = f / base;
			result = result + f * (i % base);
			i = floor(i / base);
		}
		return result;
	}

	float2 Hammersley(int i, int N)
	{
		return float2(float(i) * (1.0/float( N )), HaltonSequence(i, 3) );
	}

	float calcLOD(int cubeSize, float pdf, int NumSamples)
	{
		float lod = (0.5 * log2( (cubeSize*cubeSize)/float(NumSamples) ) + 2.0) - 0.5*log2(pdf); 
		return lod;
	}

	// http://roar11.com/2015/07/screen-space-glossy-reflections/
	float specularPowerToConeAngle(float specularPower)
	{
	 const float xi = 0.244f;

	 float exponent = 1.0f / (specularPower + 1.0f);

	 return acos(pow(xi, exponent));
	}

	float isoscelesTriangleOpposite(float adjacentLength, float coneTheta)
	{
	 // simple trig and algebra - soh, cah, toa - tan(theta) = opp/adj, opp = tan(theta) * adj, then multiply * 2.0f for isosceles triangle base
	 return 2.0f * tan(coneTheta) * adjacentLength;
	}
 
	float isoscelesTriangleInRadius(float a, float h)
	{
	 float a2 = a * a;
	 float fh2 = 4.0f * h * h;
	 return (a * (sqrt(a2 + fh2) - a)) / (4.0f * h);
	}

	float isoscelesTriangleNextAdjacent(float adjacentLength, float incircleRadius)
	{
	 // subtract the diameter of the incircle to get the adjacent side of the next level on the cone
	 return adjacentLength - (incircleRadius * 2.0f);
	}
	//

	float RayAttenBorder (float2 pos, float value)
	{
		float borderDist = min(1-max(pos.x, pos.y), min(pos.x, pos.y));
		return saturate(borderDist > value ? 1 : borderDist / value);
	}