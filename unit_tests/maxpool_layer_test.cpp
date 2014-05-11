/*
 * maxpool_layer_test.cpp
 *
 *  Created on: May 11, 2014
 *      Author: mike
 */

#include <vector>

#include <gtest/gtest.h>

#include "maxpool_layer.h"

#include "test_helper.h"

using namespace std;

Params Compute(const Params &input,
			   size_t windowSizeX, size_t windowSizeY,
			   bool isTraining = false)
{
	return MaxPoolLayer("", windowSizeX, windowSizeY)
			.Compute(0, input, isTraining);
}

Params Backprop(const Params &lastInput, const Params &outputErrors,
				size_t windowSizeX, size_t windowSizeY,
				const Params *pLastOutput = nullptr)
{
	MaxPoolLayer layer("", windowSizeX, windowSizeY);

	const Params &lastOutput = pLastOutput ?
								*pLastOutput
							  : layer.Compute(0, lastInput, true);

	Params ret = layer.Backprop(0, lastInput, lastOutput, outputErrors);

	return move(ret);
}

TEST(MaxPoolLayerTest, Degenerate)
{
	CMatrix input(9, 2);
	input << 1, 1,
			 2, 2,
			 3, 3,
			 4, 40,
			 5, 5,
			 6, 6,
			 7, 7,
			 8, 8,
			 9, 9;

	CMatrix correctOutput(1, 2);
	correctOutput << 9, 40;

	Params comp = Compute(Params(3, 3, 1, input), 3, 3);

	AssertMatrixEquivalence(correctOutput, comp.Data);
}

TEST(MaxPoolLayerTest, Normal)
{
	CMatrix input(81, 1);
	input <<  1,  4, -2,     5,  5, .1,   -2, -3,  1,
			 -7, 14, 12,    -1, -7,  9,   -3,  1, -1,
			  1,  1,  1,     1,  1,  1,    1,  1,  1,

			  2,  1,  3,    17, -1,  4,    1,  1,  1,
			  3,  4,  2,     6,  1,  1,    1,  1,  1,
			  4,  7,  1,     0,  2,  3,    1,  1,  1,

			  2,  2,  1,     1,  2,  3,    4,  5,  6,
			  3,  3, -1,     7,  8,  9,   10, 11, 12,
			 13, 14, 15,    16, 17, 18,   19, 20, 21;

	CMatrix correctOutput(9, 1);
	correctOutput << 14,  9,  1,
					  7, 17,  1,
					 15, 18, 21;

	Params comp = Compute(Params(9, 9, 1, input), 3, 3);

	AssertMatrixEquivalence(correctOutput, comp.Data);


}
