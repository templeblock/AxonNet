/*
 * cu_convo_layer.cu
 *
 *  Created on: Jun 15, 2014
 *      Author: mike
 */

#include "cu_convo_layer.cuh"

#include "cusetup_provider.cuh"
#include "cu_weights.cuh"
#include "cumath_functions.cuh"

using namespace std;

class CuConvoLayer::Impl
{
private:
	CuContext _handle;

	CuWeights _weights;

	CuMat _cacheCompute;
	CuMat _cacheBackprop;

	int _windowSizeX, _windowSizeY;
	int _padWidth, _padHeight;
	int _strideX, _strideY;

public:
	Impl(int deviceId,
		 int windowSizeX, int windowSizeY,
		 int strideX, int strideY,
		 int padWidth, int padHeight)
		: _windowSizeX(windowSizeX), _windowSizeY(windowSizeY),
		  _padWidth(padWidth), _padHeight(padHeight),
		  _strideX(strideX), _strideY(strideY)
	{
		_handle = CuSetupProvider::GetHandle(deviceId);

		_weights.SetHandle(_handle);

		_cacheCompute.SetHandle(_handle);
		_cacheCompute.SetSharedModify(true);

		_cacheBackprop.SetHandle(_handle);
		_cacheBackprop.SetSharedModify(true);
	}
	~Impl()
	{
	}

	Params Compute(const Params &input);
	Params Backprop(const Params &lastInput, const Params &lastOutput,
					const Params &outputErrors);

	void ApplyGradient();

	void SyncToDevice(const CWeights &hWeights, bool gradToo);
	void SyncToHost(CWeights &hWeights, bool gradToo) const;

	void SetLearningRate(Real rate);
	void SetMomentum(Real rate);
	void SetWeightDecay(Real rate);
};

CuConvoLayer::CuConvoLayer(int deviceId,
						   int windowSizeX, int windowSizeY,
						   int strideX, int strideY,
						   int padWidth, int padHeight)
{
	_impl = new Impl(deviceId,
					 windowSizeX, windowSizeY,
					 strideX, strideY,
					 padWidth, padHeight);
}

CuConvoLayer::~CuConvoLayer()
{
	delete _impl;
}

Params CuConvoLayer::Compute(const Params& input) const
{
    return _impl->Compute(input);
}

Params CuConvoLayer::Backprop(const Params& lastInput,
		const Params& lastOutput, const Params& outputErrors)
{
    return _impl->Backprop(lastInput, lastOutput, outputErrors);
}

void CuConvoLayer::ApplyGradient()
{
    _impl->ApplyGradient();
}

void CuConvoLayer::SyncToDevice(const CWeights& hWeights, bool gradToo)
{
    _impl->SyncToDevice(hWeights, gradToo);
}

void CuConvoLayer::SyncToHost(CWeights& hWeights, bool gradToo) const
{
    _impl->SyncToHost(hWeights, gradToo);
}

void CuConvoLayer::SetLearningRate(Real rate)
{
    _impl->SetLearningRate(rate);
}

void CuConvoLayer::SetMomentum(Real rate)
{
    _impl->SetMomentum(rate);
}



void CuConvoLayer::SetWeightDecay(Real rate)
{
    _impl->SetWeightDecay(rate);
}

struct PlacementParams
{
    int KSkipStride;
    int KInnerSkipStride;
};

struct ConvoKernelParams
{
    int IpDepth;
    int OpDepth;
    int WindowSizeX;
    int WindowSizeY;
    int StrideX;
    int StrideY;
    int PadWidth;
    int PadHeight;

    Real *WeightsBuff;
    Real *BiasBuff;

    PlacementParams Places[20];
};

template<bool padded, int numImagesPerThread>
__global__ void CuConvoLayer_Compute(const Real *gInput, Real *gOutput,
                                     const Real *gWeights, const Real *gBiases,
                                     const int ipWidth, const int ipHeight, const int ipDepth,
                                     const int opWidth, const int opHeight, const int opDepth,
                                     const int wndSizeX, const int wndSizeY,
                                     const int strideX, const int strideY,
                                     const int padWidth, const int padHeight)
{
	__shared__ extern Real sInput[];

	// Switching the x's and the z's here
    const int destX = blockIdx.z * blockDim.z + threadIdx.z;

    const int destY = blockIdx.y * blockDim.y + threadIdx.y;

    const int layer = blockIdx.x * numImagesPerThread;

    const int dIdx = threadIdx.x;

    const int ipImgSize = ipWidth * ipHeight * ipDepth;

    const Real *lInput = gInput + layer * ipImgSize;

    const int opImgSize = opWidth * opHeight * opDepth;

    Real *lOutput = gOutput + layer * opImgSize;

    const int srcX = padded ? (-padWidth + destX * strideX) : (destX * strideX);
    const int srcY = padded ? (-padHeight + destY * strideY) : (destY * strideY);

    const int xMin = padded ? max(0, srcX) : srcX;
    const int yMin = padded ? max(0, srcY) : srcY;

    const int xMax = padded ? min(srcX + wndSizeX, ipWidth) : (srcX + wndSizeX);
    const int yMax = padded ? min(srcY + wndSizeY, ipHeight) : (srcY + wndSizeY);

    const int kSkipX = padded ? (xMin - srcX) : 0;
    const int kSkipY = padded ? (yMin - srcY) : 0;

    const int iStride = ipWidth * ipDepth;
    const int kStride = wndSizeX * ipDepth;

    const int kfSkipStride = padded ? ((kSkipY * kStride + kSkipX * ipDepth) * opDepth) : 0;
    const int kInnerSkipStride = padded ? ((kSkipX + (srcX + wndSizeX - xMax)) * ipDepth * opDepth) : 0;

    const int xEnd = xMax * ipDepth;

    const int dxMin = xMin * ipDepth;

    //int imgIdx = yMin * iStride;
    int weightsIdx = padded ? (dIdx + kfSkipStride) : dIdx;

    const int endImgIdx = yMax * iStride;

    const int procInputWidth = padded ? (xEnd - dxMin) : (wndSizeX * ipDepth);
    const int procInputSize = padded ? (procInputWidth * (yMax - yMin)) : (procInputWidth * wndSizeY);

    /// !!!! Load the image buffer into shared memory !!!!
    // Calculate the number of warps that are in this block.
    // For coalesced access rules, we want these guys to be grouped on a row
    const int numWarps = blockDim.x / 32;

    // Not enough threads to even fill a single warp...
    // This will not be ultra-efficient
    if (numWarps <= 1)
    {
        const int startCol = dxMin + threadIdx.x;

        for (int iY = 0, imgIdx = yMin * iStride;
                imgIdx < endImgIdx;
                ++iY, imgIdx += iStride)
        {
            for (int iX = startCol; iX < xEnd; iX += blockDim.x)
            {
				#pragma unroll
            	for (int k = 0; k < numImagesPerThread; ++k)
            	{
            		const Real iVal = lInput[imgIdx + (k * ipImgSize) + iX];

            		sInput[(k * procInputSize) + (iY * procInputWidth + iX - dxMin)] = iVal;
            	}
            }
        }
    }
    else
    {
        const int warpsPerRow = round_up(numWarps, yMax - yMin);
        const int simulRows = numWarps / warpsPerRow;

        // Let each warp do a separate row
        const int startRow = threadIdx.x / (32 * warpsPerRow);
        const int startCol = dxMin + (threadIdx.x % (32 * warpsPerRow));

        for (int iY = startRow, imgIdx = (yMin + startRow) * iStride;
                 imgIdx < endImgIdx;
                 iY += simulRows, imgIdx += (simulRows * iStride))
        {
            for (int iX = startCol; iX < xEnd; iX += (32 * warpsPerRow))
            {
				#pragma unroll
            	for (int k = 0; k < numImagesPerThread; ++k)
            	{
            		const Real iVal = lInput[imgIdx + (k * ipImgSize) + iX];

            		sInput[(k * procInputSize) + (iY * procInputWidth + iX - dxMin)] = iVal;
            	}
            }
        }
    }

    __syncthreads();

    //Real sum = gBiases[dIdx];
    Real sum[numImagesPerThread] = { 0.0f };

    // Peel vectors of 8
    const int vecProcX = procInputWidth & ~0x7;
    const int vecTailX = procInputWidth & 0x7;

    const int vecXend = dxMin + vecProcX;

    int ipIdx = 0;
    for (int iY = yMin; iY < yMax; ++iY)
    {
    	for (int iX = dxMin; iX < vecXend; iX += 8)
    	{
			#pragma unroll
    		for (int i = 0; i < 8; ++i)
    		{
    			const Real kVal = gWeights[weightsIdx + i * opDepth];

				#pragma unroll
    			for (int k = 0; k < numImagesPerThread; ++k)
    			{
    				const Real iVal = sInput[ipIdx + (k * procInputSize) + i];

    				const Real product = iVal * kVal;

    				sum[k] += product;
    			}
    		}

    		ipIdx += 8;
    		weightsIdx += 8 * opDepth;
    	}

#define DUFF_CASE(v) case v: \
			{ \
			const Real kVal = gWeights[weightsIdx + (v - 1) * opDepth]; \
			_Pragma("unroll") \
    		for (int k = 0; k < numImagesPerThread; ++k) \
    		{ \
    			sum[k] += sInput[ipIdx + (k * procInputSize) + (v - 1)] * kVal; \
    		} }

    	switch (vecTailX)
    	{
    	DUFF_CASE(7);
    	DUFF_CASE(6);
    	DUFF_CASE(5);
    	DUFF_CASE(4);
    	DUFF_CASE(3);
    	DUFF_CASE(2);
    	DUFF_CASE(1);
    	case 0:
    		break;
    	}

    	ipIdx += vecTailX;
    	weightsIdx += (padded ? kInnerSkipStride : 0) + vecTailX * opDepth;

#undef DUFF_CASE

        // Skip over the padding parts of the filter
        //weightsIdx += kInnerSkipStride;
    }

    const int opStoreIdx = destY * opWidth * opDepth + destX * opDepth;

    // Finally, store the sum
    //lOutput[opStoreIdx + dIdx] = sum;
    const Real bias = gBiases[dIdx];
	#pragma unroll
    for (int k = 0; k < numImagesPerThread; ++k)
    {
    	lOutput[opStoreIdx + (k * opImgSize) + dIdx] = sum[k] + bias;
    }
}

Params CuConvoLayer::Impl::Compute(const Params& input)
{
    const CuMat &mInput = input.GetCudaMatrix(_handle);

    const int ipWidth = input.Width;
    const int ipHeight = input.Height;
	const int ipDepth = input.Depth;
	const int batchSize = input.Cols;

	const int ipEffectiveWidth = ipWidth + _padWidth * 2,
		      ipEffectiveHeight = ipHeight + _padHeight * 2;

	const int opWidth = (int) floor((ipEffectiveWidth - _windowSizeX) / float(_strideX)) + 1;
	const int opHeight = (int) floor((ipEffectiveHeight - _windowSizeY) / float(_strideY)) + 1;
	const int opDepth = _weights.Weights.Rows();

	_cacheCompute.Resize(opWidth * opHeight * opDepth, batchSize);
	Params output(opWidth, opHeight, opDepth,
	            new CuMat(_cacheCompute));

	CuMat &mOutput = output.GetCudaMatrix(_handle);

	cudaError_t err = cudaSetDevice(_handle.Device);

	if (err != cudaSuccess)
	    throw runtime_error("Unable to set the device.");

	if (opDepth > 1024)
		throw runtime_error("Output depths greater than 1024 are not supported.");

	uint32_t blockDepth = opDepth;

	dim3 blockSize(blockDepth, 1, 1);
	dim3 gridSize = round_up(blockDepth * batchSize, opHeight, opWidth, blockSize);

	uint32_t smemSize = _windowSizeX * _windowSizeY * ipDepth * sizeof(Real);

	uint32_t numImagesPerThread = 1;
	for (int i = 4; i > 1; --i)
	{
		if ((batchSize % i) == 0)
		{
			numImagesPerThread = i;
			break;
		}
	}

	smemSize *= numImagesPerThread;
	gridSize.x /= numImagesPerThread;

	//cudaFuncSetCacheConfig(CuConvoLayer_Compute, cudaFuncCachePreferShared);

	bool padded = _padWidth > 0 || _padHeight > 0;

#define LAUNCH_CONVO_KERNEL(p, v) \
			CuConvoLayer_Compute \
				<p, v> \
				<<<gridSize, blockSize, smemSize>>> \
					(mInput.Buff(), mOutput.Buff(), \
				     _weights.Weights.Buff(), _weights.Biases.Buff(), \
				     ipWidth, ipHeight, ipDepth, \
				     opWidth, opHeight, opDepth, \
				     _windowSizeX, _windowSizeY, \
				     _strideX, _strideY, \
				     _padWidth, _padHeight)

#define PADDED_B(v) \
	if (padded) \
		LAUNCH_CONVO_KERNEL(true, v); \
	else \
		LAUNCH_CONVO_KERNEL(false, v)

	switch (numImagesPerThread)
	{
	case 1:
		PADDED_B(1);
		break;
	case 2:
		PADDED_B(2);
		break;
	case 3:
		PADDED_B(3);
		break;
	case 4:
		PADDED_B(4);
		break;
	}

#undef PADDED_B
#undef LAUNCH_CONVO_KERNEL

	/*CuConvoLayer_Compute
        <<<gridSize, blockSize, smemSize>>>
                        (mInput.Buff(), mOutput.Buff(),
                         _weights.Weights.Buff(), _weights.Biases.Buff(),
                         ipWidth, ipHeight, ipDepth,
                         opWidth, opHeight, opDepth,
                         _windowSizeX, _windowSizeY,
                         _strideX, _strideY,
                         _padWidth, _padHeight);*/

	err = cudaGetLastError();

	if (err != cudaSuccess)
		throw runtime_error("Unable to compute convolution.");

	return output;


}

template<bool padded>
__global__ void CuConvoLayer_NaiveBackprop(const Real *gLastInput, const Real *gLastOutput,
										   const Real *gOutputErrors, Real *gInputErrors,
										   const Real *gWeights,
										   const int ipWidth, const int ipHeight, const int ipDepth,
										   const int opWidth, const int opHeight, const int opDepth,
										   const int wndSizeX, const int wndSizeY,
										   const int strideX, const int strideY,
										   const int padWidth, const int padHeight)
{
	__shared__ extern Real shared_module[];

	const int destX = blockIdx.y * blockDim.y + threadIdx.y;
	const int destY = blockIdx.z * blockDim.z + threadIdx.z;

	const int layer = blockIdx.x;

	const int ipImgStride = ipWidth * ipDepth;
	const int ipImgSize = ipImgStride * ipHeight;
	const int opImgSize = opWidth * opHeight * opDepth;

	const Real *lOutputErrors = gOutputErrors + opImgSize * layer;
	Real *lInputErrors = gInputErrors + ipImgSize * layer;

	// Compute the input error module.
	// No need to worry about padding here
	{
		const int weightsSize = wndSizeX * wndSizeY * ipDepth * opDepth;

		// The weights matrix is column major, which means that each thread
		// will operate on contiguous memory.
		const int startIdx = threadIdx.x * opDepth;
		const int threadStride = blockDim.x * opDepth;

		const int opErrIdx = destY * opWidth * opDepth + destX * opDepth;

		// A thread block doesn't necessarily process the entire block
		// at once
		for (int currRow = startIdx, i = threadIdx.x; currRow < weightsSize;
				currRow += threadStride, i += blockDim.x)
		{
			Real val = 0.0f;
			for (int wI = 0; wI < opDepth; ++wI)
			{
				const Real wVal = gWeights[currRow + wI];
				const Real errVal = lOutputErrors[opErrIdx + wI];

				val += wVal * errVal;
			}

			shared_module[i] = val;
		}

		// Ok, at this point, all of the input errors for this module are stored in
		// shared memory. The next step is to write this module out into the input
		// error buffer.
		__syncthreads();
	}

	// Be lazy about padding...
	const int srcX = padded ? (-padWidth + destX * strideX) : (destX * strideX);
    const int srcY = padded ? (-padHeight + destY * strideY) : (destY * strideY);

    // We know that the thread block size is a factor of the module stride
    const int yStart = max(srcY, 0);
    const int yEnd = min(srcY + wndSizeY, ipHeight);

    const int xStart = max(srcX * ipDepth, 0);
    const int xEnd = min((srcX + wndSizeX), ipWidth) * ipDepth;

    const int yOff = max(-srcY, 0);
    const int xOff = max(-srcX, 0) * ipDepth;

    const int moduleStride = wndSizeX * ipDepth;

    int opYIdx = yStart * ipImgStride;
    int ipYIdx = yOff * moduleStride;
    for (int y = yStart; y < yEnd; ++y, opYIdx += ipImgStride, ipYIdx += moduleStride)
    {
    	for (int x = xStart + threadIdx.x; x < xEnd; x += blockDim.x)
    	{
    		const Real sVal = shared_module[ipYIdx + xOff + x];

    		Real *dVal = lInputErrors + opYIdx + x;

    		// TODO: It is really ugly to use atomics here...
    		atomicAdd(dVal, sVal);
    	}
    }
}

Params CuConvoLayer::Impl::Backprop(const Params& lastInput,
        const Params& lastOutput, const Params& outputErrors)
{
	const int ipWidth = lastInput.Width;
	const int ipHeight = lastInput.Height;
	const int ipDepth = lastInput.Depth;
	const int batchSize = lastInput.Cols;

	const int opWidth = lastOutput.Width;
	const int opHeight = lastOutput.Height;
	const int opDepth = lastOutput.Depth;

	_cacheBackprop.Resize(ipWidth * ipHeight * ipDepth, batchSize);
	Params inputErrors(ipWidth, ipHeight, ipDepth,
			   new CuMat(_cacheBackprop));

	const CuMat &mLastInput = lastInput.GetCudaMatrix(_handle);
	const CuMat &mLastOutput = lastOutput.GetCudaMatrix(_handle);
	const CuMat &mOutputErrors = outputErrors.GetCudaMatrix(_handle);
	CuMat &mInputErrors = inputErrors.GetCudaMatrix(_handle);

	// Initialize the input error matrix to 0
	mInputErrors.SetConstant(0.0f);

	cudaError_t err = cudaSetDevice(_handle.Device);

	if (err != cudaSuccess)
		throw runtime_error("Unable to set the device.");

	if (opDepth > 1024)
		throw runtime_error("Output depths greater than 1024 are not supported.");

	//if ((opDepth % 32) != 0)
	//	throw runtime_error("Only output depths that have 32 as a factor are currently supported.");

	uint32_t moduleSize = _windowSizeX * _windowSizeY * ipDepth;

	uint32_t patchSeg = _windowSizeX * ipDepth;
	if (patchSeg > 1024)
		patchSeg = max(_windowSizeX, ipDepth);
	if (patchSeg > 1024)
		patchSeg = min(_windowSizeX, ipDepth);

	assert(patchSeg <= 1024);

	// Similar to compute, the x dimension will be used as the z dimension
	dim3 blockSize(patchSeg, 1, 1);
	dim3 gridSize = round_up(batchSize * patchSeg, opWidth, opHeight, blockSize);

	uint32_t smemSize = moduleSize * sizeof(Real);

	bool padded = _padWidth > 0 || _padHeight > 0;

	// The BP kernel computes the input errors
#define LAUNCH_BP_KERNEL(p) \
			CuConvoLayer_NaiveBackprop \
				<p> \
				<<<gridSize, blockSize, smemSize>>> \
					(mLastInput.Buff(), mLastOutput.Buff(), \
					 mOutputErrors.Buff(), mInputErrors.Buff(), \
					 _weights.Weights.Buff(), \
					 ipWidth, ipHeight, ipDepth, \
					 opWidth, opHeight, opDepth, \
					 _windowSizeX, _windowSizeY, \
					 _strideX, _strideY, \
					 _padWidth, _padHeight)

	if (padded)
		LAUNCH_BP_KERNEL(true);
	else
		LAUNCH_BP_KERNEL(false);

#undef LAUNCH_BP_KERNEL

    return inputErrors;
}

void CuConvoLayer::Impl::ApplyGradient()
{
    _weights.ApplyGradient();
}

void CuConvoLayer::Impl::SyncToDevice(const CWeights& hWeights, bool gradToo)
{
    _weights.CopyToDevice(hWeights, gradToo);
}

void CuConvoLayer::Impl::SyncToHost(CWeights& hWeights, bool gradToo) const
{
    _weights.CopyToHost(hWeights, gradToo);
}

void CuConvoLayer::Impl::SetLearningRate(Real rate)
{
    _weights.LearningRate = rate;
}

void CuConvoLayer::Impl::SetMomentum(Real rate)
{
    _weights.Momentum = rate;
}

void CuConvoLayer::Impl::SetWeightDecay(Real rate)
{
    _weights.WeightDecay = rate;
}
