/*
 * File description: cu_weights.cuh
 * Author information: Mike Ranzinger mranzinger@alchemyapi.com
 * Copyright information: Copyright Orchestr8 LLC
 */

#pragma once

#include "weights.h"
#include "cumat.cuh"

class CuWeights
{
public:
    CuMat Weights;
    CuMat Biases; // TODO: Implement a cuda vector type?

    CuMat WeightsIncrement;
    CuMat BiasIncrement;

    CuMat WeightsGrad;
    CuMat BiasGrad;

    Real LearningRate;
    Real Momentum;
    Real WeightDecay;

    Real DynamicLearningRate;

    CuWeights();
    CuWeights(CuContext handle, uint32_t numInputs, uint32_t numOutputs);
    CuWeights(CuMat weights, CuMat bias);

    CuWeights(CuContext handle, const CWeights &hWeights);

    CWeights ToHost() const;

    void SetHandle(const CuContext &handle);
    void SetStream(cudaStream_t stream);

    void CopyToDevice(const CWeights &hWeights, bool gradToo = false);
    void CopyToHost(CWeights &hWeights, bool gradToo = false) const;

    void RandInit();
    void Init();
    void SetDefaults();

    void ApplyGradient();
};


