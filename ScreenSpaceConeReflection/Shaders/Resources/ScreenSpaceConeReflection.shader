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

Shader "Hidden/Screen Space Cone Reflection" 
{
	Properties 
	{
		_MainTex ("Base (RGB)", 2D) = "black" {}
	}
	
	CGINCLUDE

	#include "ScreenSpaceConeReflectionLib.cginc"

	struct VertexInput 
	{
		float4 vertex : POSITION;
		float2 texcoord : TEXCOORD;
	};

	struct VertexToFragment 
	{
		float4 pos : SV_POSITION;
		float2 uv : TEXCOORD0;
	};

	VertexToFragment VertexOutput( VertexInput i ) 
	{
		VertexToFragment o;
		UNITY_INITIALIZE_OUTPUT(VertexToFragment, o);
		o.pos = mul(UNITY_MATRIX_MVP, i.vertex);
		o.uv = i.texcoord;
		return o;
	}

	float4 sceneColor( VertexToFragment i ) : SV_Target
	{	 
		float2 uv = i.uv;

		float3 cubemap = GetCubeMap(uv);

		float4 sceneColor = tex2D(_MainTex, uv);
		sceneColor.rgb = max(1e-5, sceneColor.rgb - cubemap);

		return sceneColor;
	}

	float4 rayCast ( VertexToFragment i ) : SV_Target
	{	
		float2 uv = i.uv;

		float depth = GetDepth (uv);	
		float3 screenPos = GetScreenPos (uv, depth);
		float3 viewPos = GetViewPos (screenPos);

		float4 specular = GetSpecular (uv);
		float roughness = max(1 - specular.a, 0.05f);   
		float3 viewNormal =  GetViewNormal (GetNormal (uv));

		uint frameRandom = _TemporalNoise == 1 ? _Time.y * 1138 : 1 ;

		float2 jitter = Noise(uv.xy, frameRandom);
		jitter += 0.5f;

		float3 dir = reflect(normalize(viewPos), viewNormal);

		return RayMarch(dir, _NumSteps, viewPos, screenPos, uv, jitter.x + jitter.y);
	}

	float4 mipmap( VertexToFragment i ) : SV_Target
	{	 
		float2 uv = i.uv;

		int NumSamples = MAX_BLUR_SAMPLE;
		float4 result = 0.0f;
		for(int i = 0; i < NumSamples; i++)
		{
			float2 E = Hammersley(i, NumSamples);
			float4 H = ImportanceSampleBlinn(E, _MipMapExponent);

			float mip = calcLOD(MIP_MAP_TEXTURE_SIZE, H.w, NumSamples);

			result += tex2Dlod(_MainTex, float4(uv + H.xy,0,mip));
		}
		result /= NumSamples;

		return result;
	}

	float4 resolve( VertexToFragment i ) : SV_Target
	{	 
		float2 uv = i.uv;

		float4 specular = GetSpecular (uv);
		float roughness = GetRoughness(specular.a);

        float3 worldNormal =  GetNormal (uv);

		float depth = GetDepth (uv);	
		float3 screenPos = GetScreenPos (uv, depth);

		float specularPower = RoughnessToSpecPower(roughness);
		float coneTheta = specularPowerToConeAngle(specularPower) * 0.5f;

		float4 rayCastPacked = tex2D(_RayCast, uv.xy);
		float2 hitUv = rayCastPacked.xy;
		float hitMask = rayCastPacked.z;

		// http://roar11.com/2015/07/screen-space-glossy-reflections/
		float2 deltaP = hitUv.xy - uv.xy;
		float adjacentLength = length(deltaP);
		float2 adjacentUnit = normalize(deltaP);

		float maxMipMap = (float)MAX_MIP_MAP - 1.0f;

		int NumResolve = MAX_BLUR_SAMPLE;

		float4 result = 0.0f;
		for(int i = 0; i < NumResolve; i++)
		{
			float oppositeLength = isoscelesTriangleOpposite(adjacentLength, coneTheta);
			float incircleSize = isoscelesTriangleInRadius(oppositeLength, adjacentLength);

			float2 samplePos = uv + adjacentUnit * (adjacentLength - incircleSize);

			float mip = clamp(log2(incircleSize * max(_ScreenParams.x, _ScreenParams.y)), 0.0f, maxMipMap);

            float3 reflection = tex2Dlod(_MainTex, float4(samplePos, 0, mip));

			result.xyz += reflection;
			result.w += RayAttenBorder (hitUv, _EdgeFactor) * hitMask;

			adjacentLength = isoscelesTriangleNextAdjacent(adjacentLength, incircleSize);
		}
		result /= NumResolve;

		return result; 
	}

	float4 combine( VertexToFragment i ) : SV_Target
	{	 
		float2 uv = i.uv;

		float depth = GetDepth (uv);	
		float3 screenPos = GetScreenPos (uv, depth);
		float3 worldPos = GetWorlPos (screenPos);

		float4 specular = GetSpecular (uv);
		float roughness = GetRoughness(specular.a);
        float3 worldNormal =  GetNormal (uv);

		float3 viewDir = GetViewDir (worldPos);
		float NdotV = saturate(dot(worldNormal , -viewDir));

		float4 sceneColor = GetSceneColor(uv);
		float4 reflection = GetReflection(uv);
		float3 cubemap = GetCubeMap(uv);

		reflection.rgb *= F_LazarovApprox( specular, roughness, NdotV);

		if(_DebugPass == 0)
			sceneColor.rgb += lerp(cubemap, reflection.rgb, sqr(reflection.a));
		if(_DebugPass == 1)
			sceneColor.rgb += lerp(float3(0.0f, 0.0f, 0.0f), reflection.rgb, sqr(reflection.a));
		if(_DebugPass == 2)
			sceneColor.rgb = lerp(cubemap, reflection.rgb, sqr(reflection.a));
		if(_DebugPass == 3)
			sceneColor.rgb = reflection.rgb * sqr(reflection.a);
		if(_DebugPass == 4)
			sceneColor.rgb = cubemap;

		return sceneColor; 
	}
	ENDCG 
	
	Subshader 
	{
		//0
		Pass 
		{
			ZTest Always Cull Off ZWrite Off
			Fog { Mode off }

			CGPROGRAM
			#pragma target 3.0
			
			#ifdef SHADER_API_OPENGL
       			#pragma glsl
    		#endif

			#pragma fragmentoption ARB_precision_hint_fastest
			#pragma vertex VertexOutput
			#pragma fragment sceneColor
			ENDCG
		}
		//1
		Pass 
		{
			ZTest Always Cull Off ZWrite Off
			Fog { Mode off }

			CGPROGRAM
			#pragma target 3.0
			
			#ifdef SHADER_API_OPENGL
       			#pragma glsl
    		#endif

			#pragma fragmentoption ARB_precision_hint_fastest
			#pragma vertex VertexOutput
			#pragma fragment rayCast
			ENDCG
		}
		//2
		Pass 
		{
			ZTest Always Cull Off ZWrite Off
			Fog { Mode off }

			CGPROGRAM
			#pragma target 3.0
			
			#ifdef SHADER_API_OPENGL
       			#pragma glsl
    		#endif

			#pragma fragmentoption ARB_precision_hint_fastest
			#pragma vertex VertexOutput
			#pragma fragment resolve
			ENDCG
		}
		//3
		Pass 
		{
			ZTest Always Cull Off ZWrite Off
			Fog { Mode off }

			CGPROGRAM
			#pragma target 3.0
			
			#ifdef SHADER_API_OPENGL
       			#pragma glsl
    		#endif

			#pragma fragmentoption ARB_precision_hint_fastest
			#pragma vertex VertexOutput
			#pragma fragment mipmap
			ENDCG
		}
		//4
		Pass 
		{
			ZTest Always Cull Off ZWrite Off
			Fog { Mode off }

			CGPROGRAM
			#pragma target 3.0
			
			#ifdef SHADER_API_OPENGL
       			#pragma glsl
    		#endif

			#pragma fragmentoption ARB_precision_hint_fastest
			#pragma vertex VertexOutput
			#pragma fragment combine
			ENDCG
		}
	}
	Fallback Off
}
