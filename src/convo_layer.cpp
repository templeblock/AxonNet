#include "convo_layer.h"

#include "util/enum_to_string.h"
#include "memset_util.h"

/*
using namespace std;
using namespace axon::serialization;

ConvoLayer::ConvoLayer(string name, 
						size_t inputDepth, size_t outputDepth, 
						size_t windowSizeX, size_t windowSizeY, 
						size_t strideX, size_t strideY, 
						PaddingMode padMode,
						Vector constPad)
	: LayerBase(move(name)), 
	  	_inputDepth(inputDepth),
		_linearLayer("", inputDepth * windowSizeX * windowSizeY, outputDepth),
		_windowSizeX(windowSizeX), _windowSizeY(windowSizeY), 
		_strideX(strideX), _strideY(strideY), _padMode(padMode),
		_constPad(move(constPad))
{
	PrepareForThreads(1);
}

ConvoLayer::ConvoLayer(std::string name,
						RMatrix linWeights, Vector linBias,
						size_t windowSizeX, size_t windowSizeY,
						size_t strideX, size_t strideY,
						PaddingMode padMode,
						Vector constPad)
	: LayerBase(move(name)),
		_linearLayer("", move(linWeights), move(linBias)),
		_windowSizeX(windowSizeX), _windowSizeY(windowSizeY),
		_strideX(strideX), _strideY(strideY), _padMode(padMode),
		_constPad(constPad)
{
	PrepareForThreads(1);
}

Params ConvoLayer::Compute(int threadIdx, const Params &unpaddedInput, bool isTraining)
{
	if (_linearLayer.InputSize() != unpaddedInput.Depth * _windowSizeX * _windowSizeY)
	{
		assert(false);
		throw runtime_error("The underlying linear layer doesn't take the correct input dimensions.");
	}

	switch (unpaddedInput.Layout)
	{
	case Params::Packed:
		return ComputePacked(threadIdx, unpaddedInput, isTraining);
	case Params::Planar:
		return ComputePlanar(threadIdx, unpaddedInput, isTraining);
	default:
		throw runtime_error("Unsupported parameter layout.");
	}
}

Params ConvoLayer::ComputePacked(int threadIdx, const Params &unpaddedInput, bool isTraining)
{
	const Params pInput = GetPaddedInput(unpaddedInput);

	const size_t ipWidth = pInput.Width;
	const size_t ipHeight = pInput.Height;

	const size_t opWidth = (size_t) ceil((pInput.Width - _windowSizeX + 1) / float(_strideX));
	const size_t opHeight = (size_t) ceil((pInput.Height - _windowSizeY + 1) / float(_strideY));
	const size_t opDepth = _linearLayer.OutputSize();

	Params output(opWidth, opHeight, opDepth, Vector(opWidth * opHeight * opDepth));

	Params window(_windowSizeX, _windowSizeY, pInput.Depth, Vector(_windowSizeX * _windowSizeY * pInput.Depth));

	const size_t inputStride = pInput.Width * pInput.Depth;
	const size_t windowStride = window.Width * window.Depth;

	MultiParams &threadPrms = _threadWindows[threadIdx];
	threadPrms.clear();
	threadPrms.reserve(opWidth * opHeight);

	for (size_t ipY = 0, opIdx = 0; ipY < ipHeight - _windowSizeY + 1; ipY += _strideY)
	{
		for (size_t ipX = 0;
			ipX < (ipWidth - _windowSizeX + 1) * pInput.Depth;
			ipX += (_strideX * pInput.Depth), opIdx += opDepth)
		{
			const Real *srcPtr = pInput.Data.data() + (ipY * inputStride) + ipX;
			Real *wndPtr = window.Data.data();
			for (size_t wndY = 0; wndY < _windowSizeY; ++wndY, srcPtr += inputStride, wndPtr += windowStride)
			{
				copy(srcPtr, srcPtr + windowStride, wndPtr);
			}

			// Convolve this window, and write it into the output buffer
			_linearLayer.Compute(threadIdx, window, output.Data.data() + opIdx);

			// If training, store the inputs
			if (isTraining)
				threadPrms.push_back(window);
		}
	}

	return move(output);
}

Params ConvoLayer::ComputePlanar(int threadIdx, const Params &unpaddedInput, bool isTraining)
{
	throw runtime_error("Planar input data is not currently supported.");
}

Params ConvoLayer::Backprop(int threadIdx, const Params &lastInput, const Params &lastOutput, const Params &outputErrors)
{
	MultiParams &linearInputs = _threadWindows[threadIdx];

	size_t opDepth = _linearLayer.OutputSize();

	size_t numOut = outputErrors.Data.size() / opDepth;

	// Get the output errors
	MultiParams linearOutputErrors(numOut, Params(1, 1, opDepth, Vector()));
	for (size_t i = 0, end = linearOutputErrors.size(); i < end; ++i)
	{
		linearOutputErrors[i].Data = outputErrors.Data.block(i * opDepth, 0, opDepth, 1);
	}

	MultiParams linearInputErrors = _linearLayer.BackpropMany(threadIdx, linearInputs, linearOutputErrors);

	// The input error is the windowed sum of the linear input errors
	Params paddedInputErrors = GetZeroPaddedInput(lastInput);

	RMap paddedMap(paddedInputErrors.Data.data(), paddedInputErrors.Height, paddedInputErrors.Width * paddedInputErrors.Depth);

	//Matrix wndMat(_windowSizeY, _windowSizeX * opDepth);
	size_t wndWidth = _windowSizeX * lastInput.Depth;
	size_t wndHeight = _windowSizeY;

	for (size_t ipY = 0, errIdx = 0; ipY < paddedInputErrors.Height - _windowSizeY + 1; ipY += _strideY)
	{
		for (size_t ipX = 0; 
				ipX < (paddedInputErrors.Width - _windowSizeX + 1) * lastInput.Depth; 
				ipX += _strideX * lastInput.Depth, ++errIdx)
		{
			Params &linearIpErr = linearInputErrors[errIdx];

			RMap mIpErr(linearIpErr.Data.data(), wndHeight, wndWidth);

			paddedMap.block(ipY, ipX, wndHeight, wndWidth) += mIpErr;
		}
	}

	if (_padMode == NoPadding)
		return move(paddedInputErrors);

	Params unpaddedInputErrors(lastInput, Vector(lastInput.size()));

	RMap mUpInput(unpaddedInputErrors.Data.data(), lastInput.Height, lastInput.Width * lastInput.Depth);

	mUpInput = paddedMap.block(_windowSizeY / 2, (_windowSizeX / 2) * lastInput.Depth,
		lastInput.Height, lastInput.Width * lastInput.Depth);

	return move(unpaddedInputErrors);
}

Params ConvoLayer::GetPaddedInput(const Params &input) const
{
	if (_padMode == NoPadding)
		return input;

	size_t halfWindowSizeX = _windowSizeX / 2,
		   halfWindowSizeY = _windowSizeY / 2;

	Params ret(input.Width + _windowSizeX - 1, input.Height + _windowSizeY - 1, input.Depth, Vector());
	ret.Data.resize(ret.size());

	if (_padMode == ZeroPad)
	{
		ret.Data.setZero();
	}
	else if (_padMode == ConstantPad)
	{
		memsetMany(ret.Data.data(), _constPad.data(), _constPad.size(), ret.size() / _constPad.size());
	}
	else
		throw runtime_error("Unsupported padding mode.");

	RMap mapIn(const_cast<Real*>(input.Data.data()), input.Height, input.Width * input.Depth);
	RMap mapOut(ret.Data.data(), ret.Height, ret.Width * ret.Depth);

	mapOut.block(halfWindowSizeY, halfWindowSizeX * ret.Depth, mapIn.outerSize(), mapIn.innerSize()) = mapIn;

	return move(ret);
}

Params ConvoLayer::GetZeroPaddedInput(const Params &reference) const
{
	if (_padMode == NoPadding)
	{
		return Params(reference, Vector::Zero(reference.Data.size()));
	}
	else
	{
		size_t rX = reference.Width + _windowSizeX - 1;
		size_t rY = reference.Height + _windowSizeY - 1;
		size_t rZ = reference.Depth;

		return Params(rX, rY, rZ,
			Vector::Zero(rX * rY * rZ));
	}
}

void ConvoLayer::SetConstantPad(Vector pad)
{
	if (pad.size() == 0)
		throw runtime_error("Cannot set an empty constant pad.");

	if ((_inputDepth % pad.size()) != 0 || pad.size() > _inputDepth)
		throw runtime_error("The pad must be a factor of the input depth.");

	_padMode = ConstantPad;
	_constPad.swap(pad);
}

void ConvoLayer::ApplyDeltas()
{
	_linearLayer.ApplyDeltas();
}

void ConvoLayer::ApplyDeltas(int threadIdx)
{
	_linearLayer.ApplyDeltas(threadIdx);
}

void ConvoLayer::PrepareForThreads(size_t num)
{
	_threadWindows.resize(num);

	_linearLayer.PrepareForThreads(num);
}

void ConvoLayer::SyncWithHost()
{
	_linearLayer.SyncWithHost();
}

void ConvoLayer::InitializeFromConfig(const LayerConfig::Ptr &config)
{
	LayerBase::InitializeFromConfig(config);

	auto conv = dynamic_pointer_cast<ConvoLayerConfig>(config);

	if (!conv)
		throw runtime_error("The specified config is not for a convolutional layer.");

	_linearLayer.InitializeFromConfig(conv->LinearConfig);
}

LayerConfig::Ptr ConvoLayer::GetConfig() const
{
	auto ret = make_shared<ConvoLayerConfig>();
	BuildConfig(*ret);
	return ret;
}

void ConvoLayer::BuildConfig(ConvoLayerConfig &config) const
{
	LayerBase::BuildConfig(config);

	config.LinearConfig = _linearLayer.GetConfig();
}

void BindStruct(const CStructBinder &binder, ConvoLayerConfig &config)
{
	BindStruct(binder, (LayerConfig&) config);

	binder("linearConfig", config.LinearConfig);
}

void BindStruct(const CStructBinder &binder, ConvoLayer &layer)
{
	BindStruct(binder, (LayerBase&) layer);

	int padMode = (int)layer._padMode;
	binder("windowSizeX", layer._windowSizeX)
		  ("windowSizeY", layer._windowSizeY)
		  ("strideX", layer._strideX)
		  ("strideY", layer._strideY)
		  ("padMode", padMode);
	layer._padMode = (ConvoLayer::PaddingMode)layer._padMode;
}

AXON_SERIALIZE_DERIVED_TYPE(LayerConfig, ConvoLayerConfig, ConvoLayerConfig);

AXON_SERIALIZE_DERIVED_TYPE(ILayer, ConvoLayer, ConvoLayer);
*/

