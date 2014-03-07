#include "softmax_layer.h"

using namespace std;
using namespace axon::serialization;

Vector SoftmaxLayer::Compute(int threadIdx, const Vector &input, bool isTraining)
{
	// Getting the max value and shifting the dimension is a neat trick to prevent overflow
	// NOTE: Undeflow may still occur though, but that is far less dangerous :/
	Real largest = input.maxCoeff();

	Real sum = input.unaryExpr(
		[largest](Real coeff)
		{
			return exp(coeff - largest);
		}).sum();

	Real sumDiv = 1.0 / sum;

	Vector ret = input.unaryExpr(
		[largest, sumDiv](Real coeff)
		{
			return exp(coeff - largest) * sumDiv;
		});

#if _DEBUG
	// Verify the softmax invariant that the sum of the outputs sums to 1
	Real sftSum = ret.sum();
	assert(abs(1 - sftSum) < 0.00001);
#endif

	return move(ret);
}

Vector SoftmaxLayer::Backprop(int threadIdx, const Vector &lastInput, const Vector &lastOutput,
							  const Vector &outputErrors)
{
	Vector inputErrors(outputErrors.size());
	inputErrors.setZero();

	for (size_t i = 0; i < outputErrors.size(); ++i)
	{
		for (size_t k = 0; k < outputErrors.size(); ++k)
		{
			// TODO: Get rid of this logical comparator
			inputErrors[i] += outputErrors[i] * ((i == k) - outputErrors[k]);
		}
	}

	return inputErrors;
}

void BindStruct(const CStructBinder &binder, SoftmaxLayer &layer)
{
	BindStruct(binder, (LayerBase&) layer);
}

AXON_SERIALIZE_DERIVED_TYPE(ILayer, SoftmaxLayer, SoftmaxLayer);