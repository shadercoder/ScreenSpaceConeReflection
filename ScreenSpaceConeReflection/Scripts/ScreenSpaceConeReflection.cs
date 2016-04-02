/*The MIT License(MIT)

Copyright(c) 2016 Charles Greivelding Thomas

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

using System;
using UnityEngine;

namespace cCharkes
{

    [System.Serializable]
    public enum DebugPass
    {
        Combine,
        CombineNoCubemap,
        ReflectionAndCubemap,
        Reflection,
        Cubemap
    };

	[RequireComponent(typeof (Camera))]
	[AddComponentMenu("cCharkes/Image Effects/Rendering/Screen Space Cone Reflection")]
	public class ScreenSpaceConeReflection : MonoBehaviour
	{
        [Header("RayCast")]
        [Range(1, 100)]
        [SerializeField]
        int rayDistance = 50;

        [SerializeField]
        bool temporalNoise = false;

        [Header("General")]
        [Range(0.0f, 1.0f)]
        [SerializeField]
        float screenFadeSize = 0.25f;

        [Header("Debug")]
        [Range(0.0f, 1.0f)]
        [SerializeField]
        float smoothnessRange = 1.0f;

        [SerializeField]
        DebugPass debugPass = DebugPass.Combine;

        Camera m_camera;
        int mipMapExponent = 32;

        private RenderTexture mipMapBuffer0, mipMapBuffer1;
    
        private Matrix4x4 projectionMatrix;
        private Matrix4x4 viewProjectionMatrix;
        private Matrix4x4 inverseViewProjectionMatrix;
        private Matrix4x4 worldToCameraMatrix;
 
        static Material m_rendererMaterial = null;
		protected Material rendererMaterial
		{
			get 
			{
				if (m_rendererMaterial == null) 
				{
					m_rendererMaterial = new Material(Shader.Find("Hidden/Screen Space Cone Reflection"));
					m_rendererMaterial.hideFlags = HideFlags.DontSave;
				}
				return m_rendererMaterial;
			} 
		}

        void OnEnable()
        {
            m_camera = GetComponent<Camera>();
            m_camera.depthTextureMode = DepthTextureMode.Depth;
        }

        void Awake ()
		{
            GetComponent<Camera>().depthTextureMode = DepthTextureMode.Depth;
        }
		
        void UpdateMipMapBuffer()
        {
            DestroyImmediate(mipMapBuffer0);
            mipMapBuffer0 = new RenderTexture(1024, 512, 0, RenderTextureFormat.ARGBHalf); // Using a square texture to get mip map as Unity can't generate mip map on a non squared texture
            mipMapBuffer0.filterMode = FilterMode.Bilinear;
            mipMapBuffer0.useMipMap = true;
            mipMapBuffer0.generateMips = true;
            mipMapBuffer0.Create();

            DestroyImmediate(mipMapBuffer1);
            mipMapBuffer1 = new RenderTexture(1024, 512, 0, RenderTextureFormat.ARGBHalf); // Using a square texture to get mip map as Unity can't generate mip map on a non squared texture
            mipMapBuffer1.filterMode = FilterMode.Bilinear;
            mipMapBuffer1.useMipMap = true;
            mipMapBuffer1.generateMips = false;
            mipMapBuffer1.Create();
        }

        void OnRenderImage(RenderTexture source, RenderTexture destination) 
		{
            int width = m_camera.pixelWidth;
            int height = m_camera.pixelHeight;

            UpdateMatrix();

            rendererMaterial.SetFloat("_SmoothnessRange", smoothnessRange);
            rendererMaterial.SetFloat("_EdgeFactor", screenFadeSize);
            rendererMaterial.SetInt("_NumSteps", rayDistance);

            if (!temporalNoise)
                rendererMaterial.SetInt("_TemporalNoise", 0);
            else
                rendererMaterial.SetInt("_TemporalNoise", 1);

            switch (debugPass)
            {
                case DebugPass.Combine:
                    rendererMaterial.SetInt("_DebugPass", 0);
                    break;
                case DebugPass.CombineNoCubemap:
                    rendererMaterial.SetInt("_DebugPass", 1);
                    break;
                case DebugPass.ReflectionAndCubemap:
                    rendererMaterial.SetInt("_DebugPass", 2);
                    break;
                case DebugPass.Reflection:
                    rendererMaterial.SetInt("_DebugPass", 3);
                    break;
                case DebugPass.Cubemap:
                    rendererMaterial.SetInt("_DebugPass", 4);
                    break;
            }

            RenderTexture mainBuffer = RenderTexture.GetTemporary(width, height, 0, RenderTextureFormat.DefaultHDR);

            Graphics.Blit(source, mainBuffer, rendererMaterial, 0);

            RenderTexture rayCastBuffer = RenderTexture.GetTemporary(width/2, height/2, 0, RenderTextureFormat.ARGBHalf);

            Graphics.Blit(source, rayCastBuffer, rendererMaterial, 1); // Ray marching pass

            rendererMaterial.SetTexture("_RayCast", rayCastBuffer);

            RenderTexture.ReleaseTemporary(rayCastBuffer);

            UpdateMipMapBuffer();

            Graphics.Blit(mainBuffer, mipMapBuffer0);

            Graphics.Blit(mipMapBuffer0, mipMapBuffer1);

            int maxMipMap = 11;
            for (int i = 0; i < maxMipMap; i++)
            {
               float minExponent = 0.01f;
               float stepExp = 1 / (float)mipMapExponent * (float)i + 0.01f;
               float exponent = Mathf.Max(stepExp, minExponent);

               rendererMaterial.SetFloat("_MipMapExponent", exponent);

               rendererMaterial.SetTexture("_MainTex", mipMapBuffer1);
               Graphics.SetRenderTarget(mipMapBuffer1, i);
               rendererMaterial.SetPass(3);
               DrawFullScreenQuad();
            }

            RenderTexture resolveBuffer = RenderTexture.GetTemporary(width, height, 0, RenderTextureFormat.ARGBHalf);

            Graphics.Blit(mipMapBuffer1, resolveBuffer, rendererMaterial, 2);

            rendererMaterial.SetTexture("_ReflectionBuffer", resolveBuffer);

            RenderTexture.ReleaseTemporary(resolveBuffer);

            Graphics.Blit(mainBuffer, destination, rendererMaterial, 4);

            RenderTexture.ReleaseTemporary(mainBuffer);
        }

        void UpdateMatrix()
        {
            worldToCameraMatrix = m_camera.worldToCameraMatrix;
            projectionMatrix = GL.GetGPUProjectionMatrix(m_camera.projectionMatrix, false);
            viewProjectionMatrix = projectionMatrix * worldToCameraMatrix;
            inverseViewProjectionMatrix = viewProjectionMatrix.inverse;

            rendererMaterial.SetMatrix("_ProjectionMatrix", projectionMatrix);
            rendererMaterial.SetMatrix("_InverseProjectionMatrix", projectionMatrix.inverse);
            rendererMaterial.SetMatrix("_InverseViewProjectionMatrix", inverseViewProjectionMatrix);
            rendererMaterial.SetMatrix("_WorldToCameraMatrix", worldToCameraMatrix);
        }

        public void DrawFullScreenQuad()
        {
            GL.PushMatrix();
            GL.LoadOrtho();

            GL.Begin(GL.QUADS);
            GL.MultiTexCoord2(0, 0.0f, 0.0f);
            GL.Vertex3(0.0f, 0.0f, 0.0f);

            GL.MultiTexCoord2(0, 1.0f, 0.0f);
            GL.Vertex3(1.0f, 0.0f, 0.0f);

            GL.MultiTexCoord2(0, 1.0f, 1.0f);
            GL.Vertex3(1.0f, 1.0f, 0.0f);

            GL.MultiTexCoord2(0, 0.0f, 1.0f);
            GL.Vertex3(0.0f, 1.0f, 0.0f);

            GL.End();
            GL.PopMatrix();
        }
    }
}
