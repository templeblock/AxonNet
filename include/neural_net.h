#pragma once

#include <xmmintrin.h>

#include <vector>

#include "i_layer.h"
#include "i_cost.h"
#include "i_train_provider.h"

class NEURAL_NET_API NetworkConfig
{
public:
	typedef std::shared_ptr<NetworkConfig> Ptr;

	std::vector<LayerConfig::Ptr> Configs;
	ICost::Ptr Cost;
	Real BestCorr;

	friend void BindStruct(const axon::serialization::CStructBinder &binder, NetworkConfig &config);
};

struct ThreadTrainConfig;

struct BPStat
{
	Real Error;
	size_t NumCorrect;
};

class NEURAL_NET_API NeuralNet
{
private:
	std::vector<ILayer::Ptr> _layers;
	ICost::Ptr _cost;
	Real _learnRate = 1.0;
	Real _bestCorr = 0;

	size_t _batchSize;

public:
	NeuralNet();

	void AddLayer(ILayer::Ptr layer);
	void SetCost(ICost::Ptr cost);

	template<typename LayerType, typename ...Args>
	void Add(Args &&...args)
	{
		AddLayer(std::make_shared<LayerType>(std::forward<Args>(args)...));
	}

	template<typename CostType, typename ...Args>
	void SetCost(Args &&...args)
	{
		SetCost(std::make_shared<CostType>(std::forward<Args>(args)...));
	}

	void Load(const NetworkConfig::Ptr &config);
	void Load(const std::string &chkFile);

	ICost::Ptr GetCostFn() const { return _cost; }

	ILayer::Ptr GetLayer(size_t index) const { return _layers[index]; }
	ILayer::Ptr FindLayer(const std::string &name) const;
	int GetLayerIndex(const std::string &name) const;
	int GetLayerIndex(const ILayer *layer) const;

	size_t NumLayers() const { return _layers.size(); }

	NetworkConfig::Ptr GetCheckpoint() const;

	void SetLearningRate(Real rate);

	Real GetCost(const Params &pred, const Params &labels);

	Params Compute(const Params &input);
	Params Compute(int threadIdx, const Params &input, bool isTraining);

	BPStat Backprop(int threadIdx, const Params &input, const Params &labels);

	void Train(ITrainProvider &provider, size_t maxIters, size_t testFreq,
		       const std::string &chkRoot);

	//friend void BindStruct(const axon::serialization::CStructBinder &binder, NeuralNet &config);
	friend void WriteStruct(const axon::serialization::CStructWriter &writer, const NeuralNet &net);
	friend void ReadStruct(const axon::serialization::CStructReader &reader, NeuralNet &net);

private:
	void ApplyDeltas(int threadIdx);
	void Test(ITrainProvider &provider, const std::string &chkRoot);
	void SaveCheckpoint(const std::string &chkRoot);
	void PrepareThreads(int numThreads);

	void RunTrainThread(ThreadTrainConfig &config);
};
 
