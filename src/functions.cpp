#include "functions.h"
#include <xmmintrin.h>
#include "sse_mathfun.h"

using namespace std;

Real LinearFn::Compute(Real input)
{
	return input;
}

Vector LinearFn::Compute(const Vector &input)
{
	return input;
}

Real LinearFn::Derivative(Real input)
{
	return 1;
}

Vector LinearFn::Derivative(const Vector &input)
{
	return Vector(input.size()).setOnes();
}

Real LogisticFn::Compute(Real input)
{
	return 1.0f / (1.0f + exp(-input));
}

Vector LogisticFn::Compute(const Vector &input)
{
	static const __m128 s_one = _mm_set1_ps(1);
	static const __m128 s_zero = _mm_set1_ps(0);

	Vector ret(input.size());

	const float *pInput = input.data();
	float *pOutput = ret.data();

	const float *pAvxEnd = pInput + (input.size() & ~0x3);

	for (; pInput != pAvxEnd; pInput += 4, pOutput += 4)
	{
		const __m128 ipVal = _mm_load_ps(pInput);

		const __m128 deno = _mm_add_ps(s_one, exp_ps(_mm_sub_ps(s_zero, ipVal)));

		const __m128 opVal = _mm_mul_ps(s_one, _mm_rcp_ps(deno));

		_mm_store_ps(pOutput, opVal);
	}

	for (const float *pEnd = input.data() + input.size(); pInput != pEnd; ++pInput, ++pOutput)
	{
		*pOutput = Compute(*pInput);
	}

	return move(ret);
}

Real LogisticFn::Derivative(Real input)
{
	return Derivative(input, Compute(input));
}

Real LogisticFn::Derivative(Real input, Real computeOutput)
{
	return computeOutput * (1.0f - computeOutput);
}

Vector LogisticFn::Derivative(const Vector &input)
{
	return Derivative(input, Compute(input));
}

Vector LogisticFn::Derivative(const Vector &input, Vector computeOutput)
{
	static const __m128 s_one = _mm_set1_ps(1);

	float *pVals = computeOutput.data();
	float *pSSEEnd = pVals + (input.size() & ~0x3);

	for (; pVals != pSSEEnd; pVals += 4)
	{
		const __m128 ipVal = _mm_load_ps(pVals);

		const __m128 opVal = _mm_mul_ps(ipVal, _mm_sub_ps(s_one, ipVal));

		_mm_store_ps(pVals, opVal);
	}

	for (const float *pEnd = computeOutput.data() + computeOutput.size(); pVals != pEnd; ++pVals)
	{
		*pVals = Derivative(0.0f, *pVals);
	}

	return computeOutput;
}

Real RectifierFn::Compute(Real input)
{
	return input > 0 ? input : 0;
}

Vector RectifierFn::Compute(const Vector &input)
{
	static const __m128 s_zero = _mm_set1_ps(0);

	Vector ret(input.size());

	const float *pInput = input.data();
	float *pOutput = ret.data();

	const float *pAvxEnd = pInput + (input.size() & ~0x3);

	for (; pInput != pAvxEnd; pInput += 4, pOutput += 4)
	{
		const auto val = _mm_load_ps(pInput);

		_mm_store_ps(pOutput, _mm_max_ps(s_zero, val));
	}

	for (const float *pEnd = input.data() + input.size(); pInput != pEnd; ++pInput, ++pOutput)
	{
		*pOutput = Compute(*pInput);
	}

	return move(ret);
}

Real RectifierFn::Derivative(Real input)
{
	return input > 0 ? 1 : 0;
}

Vector RectifierFn::Derivative(const Vector &input)
{
	static const __m128 s_one = _mm_set1_ps(1);
	static const __m128 s_zero = _mm_set1_ps(0);

	Vector ret(input.size());

	const float *pInput = input.data();
	float *pOutput = ret.data();

	const float *pAvxEnd = pInput + (input.size() & ~0x3);

	for (; pInput != pAvxEnd; pInput += 4, pOutput += 4)
	{
		const __m128 val = _mm_load_ps(pInput);

		const __m128 gt0 = _mm_cmpgt_ps(val, s_zero);

		const __m128 rVal = _mm_or_ps(_mm_and_ps(gt0, s_one), _mm_andnot_ps(gt0, s_zero));

		_mm_store_ps(pOutput, rVal);
	}

	for (const float *pEnd = input.data() + input.size(); pInput != pEnd; ++pInput, ++pOutput)
	{
		*pOutput = Derivative(*pInput);
	}

	return move(ret);
}

Real SoftPlusFn::Compute(Real input)
{
	if (input > 20)
		return input;

	return log(1 + exp(input));
}

Vector SoftPlusFn::Compute(const Vector &input)
{
	static const __m128 s_1 = _mm_set1_ps(1);
	static const __m128 s_20 = _mm_set1_ps(20);

	Vector ret(input.size());

	const float *pInput = input.data();
	float *pOutput = ret.data();

	const float *pAvxEnd = pInput + (input.size() & ~0x3);

	for (; pInput != pAvxEnd; pInput += 4, pOutput += 4)
	{
		const __m128 val = _mm_load_ps(pInput);

		const __m128 gt20 = _mm_cmpgt_ps(val, s_20);

		const __m128 soft = log_ps(_mm_add_ps(s_1, exp_ps(val)));

		const __m128 result = _mm_or_ps(_mm_and_ps(gt20, val), _mm_andnot_ps(gt20, soft));

		_mm_store_ps(pOutput, result);
	}

	for (const float *pEnd = input.data() + input.size(); pInput != pEnd; ++pInput, ++pOutput)
	{
		*pOutput = Compute(*pInput);
	}

	return move(ret);
}

Real SoftPlusFn::Derivative(Real input)
{
	return LogisticFn::Compute(input);
}

Vector SoftPlusFn::Derivative(const Vector &input)
{
	return LogisticFn::Compute(input);
}

Real TanhFn::Compute(Real input)
{
	Real e = exp(-input);

	return (1.0f - e) / (1.0 + e);
}

Vector TanhFn::Compute(const Vector &input)
{
	static const __m128 s_0 = _mm_set1_ps(0);
	static const __m128 s_1 = _mm_set1_ps(1);

	Vector ret(input.size());

	const float *pInput = input.data();
	float *pOutput = ret.data();

	const float *pAvxEnd = pInput + (input.size() & ~0x3);

	for (; pInput != pAvxEnd; pInput += 4, pOutput += 4)
	{
		const __m128 val = _mm_load_ps(pInput);

		const __m128 e = exp_ps(_mm_sub_ps(s_0, val));

		const __m128 result = _mm_div_ps(
								_mm_sub_ps(s_1, e),
								_mm_add_ps(s_1, e)
							  );

		_mm_store_ps(pOutput, result);
	}

	for (const float *pEnd = input.data() + input.size(); pInput != pEnd; ++pInput, ++pOutput)
	{
		*pOutput = Compute(*pInput);
	}

	return move(ret);
}

Real TanhFn::Derivative(Real input)
{
	return Derivative(input, Compute(input));
}

Real TanhFn::Derivative(Real input, Real computeOutput)
{
	return 1.0 - Square(computeOutput);
}

Vector TanhFn::Derivative(const Vector &input)
{
	return Derivative(input, Compute(input));
}

Vector TanhFn::Derivative(const Vector &input, Vector computeOutput)
{
	static const __m128 s_one = _mm_set1_ps(1);

	float *pVals = computeOutput.data();
	float *pSSEEnd = pVals + (input.size() & ~0x3);

	for (; pVals != pSSEEnd; pVals += 4)
	{
		const __m128 ipVal = _mm_load_ps(pVals);

		const __m128 opVal = _mm_sub_ps(s_one, _mm_mul_ps(ipVal, ipVal));

		_mm_store_ps(pVals, opVal);
	}

	for (const float *pEnd = computeOutput.data() + computeOutput.size(); pVals != pEnd; ++pVals)
	{
		*pVals = Derivative(0.0f, *pVals);
	}

	return move(computeOutput);
}

Real RampFn::Compute(Real input)
{
	if (input < -2)
		return -1;
	if (input > 2)
		return 1;

	return .5 * input;
}

Real RampFn::Derivative(Real input)
{
	if (input < -2 || input > 2)
		return 0;
	return .5;
}

Real HardTanhFn::Compute(Real input)
{
	if (input < -1)
		return -1;
	else if (input > 1)
		return 1;
	return input;
}

Real HardTanhFn::Derivative(Real input)
{
	if (input < -1 || input > 1)
		return 0;
	return 1;
}