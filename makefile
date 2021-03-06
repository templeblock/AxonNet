CC=g++-4.7
ARCHITECTURE ?= -msse4.2

FLAGS=-std=c++11 -g $(ARCHITECTURE) -fPIC
DFLAGS=$(FLAGS) -D_DEBUG
UTRFLAGS=$(FLAGS) -O2 -DEIGEN_FAST_MATH
RFLAGS=$(FLAGS) -O3 -DEIGEN_NO_DEBUG -DEIGEN_FAST_MATH -fopenmp

THIRD_PARTY   ?= ../ThirdParty
EIGEN_PATH    ?= $(THIRD_PARTY)/eigen-3-2-1
BOOST_PATH    ?= $(THIRD_PARTY)/boost_1_55_0
GTEST_PATH    ?= $(THIRD_PARTY)/gtest
AXON_PATH     ?= ../axon

CUDA_INSTALL_PATH ?= /usr/local/cuda
CUDA_INCLUDE_PATH ?= $(CUDA_INSTALL_PATH)/include
CUDA_LIB_PATH     ?= $(CUDA_INSTALL_PATH)/lib64
NVCC              ?= $(CUDA_INSTALL_PATH)/bin/nvcc
CUDA_INSTALL_LIBS := -lcudart -lcublas -lcuda -L$(CUDA_LIB_PATH)
CUDA_SDK          ?= 6.0
CUDA_ARCHITECTURE ?= -arch=sm_30
NVCCFLAGS := --ptxas-options=-v -D_CUDA_COMPILE_ $(CUDA_ARCHITECTURE) -Xcudafe "--diag_suppress=boolean_controlling_expr_is_constant" -Xcudafe "--diag_suppress=code_is_unreachable" -Xcompiler -fPIC
DNVCCFLAGS := $(NVCCFLAGS) -G -g
RNVCCFLAGS := $(NVCCFLAGS) -O3


INC_ROOT = include
SRC_ROOT = src

CUDA_INC_ROOT = cuinclude
CUDA_SRC_ROOT = cusrc

SRC = $(wildcard $(SRC_ROOT)/*.cpp)

CUDA_SRC = $(wildcard $(CUDA_SRC_ROOT)/*.cu)

OBJ_ROOT = obj

OBJS = $(patsubst $(SRC_ROOT)/%.cpp,$(OBJ_ROOT)/%.cpp.o,$(SRC))
OBJS_D = $(patsubst %.o, %.od,$(OBJS))

CUDA_OBJS = $(patsubst $(CUDA_SRC_ROOT)/%.cu,$(OBJ_ROOT)/%.cu.o,$(CUDA_SRC))
CUDA_OBJS_D = $(patsubst %.o, %.od,$(CUDA_OBJS))

NET_SRC=$(wildcard $(SRC_ROOT)/*.cpp)
TRAINER_SRC=$(wildcard Trainer/*.cpp)

UNIT_SRC_ROOT = unit_tests
UNIT_SRC=$(wildcard $(UNIT_SRC_ROOT)/*.cpp)
CUDA_UNIT_SRC=$(wildcard $(UNIT_SRC_ROOT)/*.cu)

UNIT_OBJS := $(patsubst $(UNIT_SRC_ROOT)/%.cpp,$(OBJ_ROOT)/%.cpp.o,$(UNIT_SRC))
UNIT_OBJS += $(patsubst $(UNIT_SRC_ROOT)/%.cu,$(OBJ_ROOT)/%.cu.o,$(CUDA_UNIT_SRC))

UNIT_OBJS_D = $(patsubst %.o, %.od, $(UNIT_OBJS))

TRAINER_EXE=trainer
TRAINER_EXE_D=d_trainer

UNIT_EXE=unit_test
UNIT_EXE_D=d_unit_test

INCLUDES= -I$(AXON_PATH)/include \
	      -I$(EIGEN_PATH) \
	      -I$(BOOST_PATH)/include \
	      -I$(GTEST_PATH)/include \
          -I$(INC_ROOT) \
          -I$(CUDA_INC_ROOT)

CUDA_INCLUDES = -I$(CUDA_INCLUDE_PATH) \
				-I$(EIGEN_PATH) \
				-I$(CUDA_INC_ROOT) \
				-I$(INC_ROOT) \
				-I$(GTEST_PATH)/include \
                -I$(BOOST_PATH)/include

LIBS_BASE=-L$(BOOST_PATH)/lib \
		  -L$(AXON_PATH)/lib \
		  -L$(GTEST_PATH)/lib \
		  -lboost_system -lboost_filesystem -lboost_program_options \
		  -lboost_thread -lpthread
		  
LIBS=$(LIBS_BASE) -laxcomm -laxser -laxutil -lgomp
LIBS_D=$(LIBS_BASE) -laxcommd -laxserd -laxutild

CUDA_LIBS=$(CUDA_INSTALL_LIBS) $(LIBS)
CUDA_LIBS_D=$(CUDA_INSTALL_LIBS) $(LIBS_D)

.PHONY: all clean setup net test train

all: debug release 

debug: setup lib/libaxnetd.so $(TRAINER_EXE_D) $(UNIT_EXE_D)

release: setup lib/libaxnet.so $(TRAINER_EXE) $(UNIT_EXE)

net: setup lib/libaxnetd.so lib/libaxnet.so

test: setup $(UNIT_EXE_D) $(UNIT_EXE)

train: setup $(TRAINER_EXE_D) $(TRAINER_EXE)

$(OBJ_ROOT)/%.cpp.od: $(SRC_ROOT)/%.cpp
	$(CC) $(DFLAGS) -c $< $(INCLUDES) -o $@ $(LIBS_D)

$(OBJ_ROOT)/%.cpp.o: $(SRC_ROOT)/%.cpp
	$(CC) $(RFLAGS) -c $< $(INCLUDES) -o $@ $(LIBS)

$(OBJ_ROOT)/%.cu.od: $(CUDA_SRC_ROOT)/%.cu
	$(NVCC) $(DNVCCFLAGS) -c $< $(CUDA_INCLUDES) -o $@ $(CUDA_LIBS_D)
	
$(OBJ_ROOT)/%.cu.o: $(CUDA_SRC_ROOT)/%.cu
	$(NVCC) $(RNVCCFLAGS) -c $< $(CUDA_INCLUDES) -o $@ $(CUDA_LIBS)

lib/libaxnetd.so: $(OBJS_D) $(CUDA_OBJS_D)
	$(CC) $(DFLAGS) -shared -o $@ \
                $(OBJS_D) $(CUDA_OBJS_D) \
                $(LIBS_D) $(CUDA_LIBS_D)

lib/libaxnet.so: $(OBJS) $(CUDA_OBJS)
	$(CC) $(RFLAGS) -shared -o $@ \
                $(OBJS) $(CUDA_OBJS) \
                $(LIBS) $(CUDA_LIBS)

$(TRAINER_EXE_D): $(TRAINER_SRC) lib/libaxnetd.so
	$(CC) $(DFLAGS) $(TRAINER_SRC) -o $@ \
		$(INCLUDES) $(CUDA_INCLUDES) \
                -Llib \
                -laxnetd \
                $(LIBS_D) $(CUDA_LIBS_D)

$(TRAINER_EXE): $(TRAINER_SRC) lib/libaxnet.so
	$(CC) $(RFLAGS) $(TRAINER_SRC) -o $@ \
		$(INCLUDES) $(CUDA_INCLUDES) \
                -Llib \
                -laxnet \
                $(LIBS) $(CUDA_LIBS)

$(OBJ_ROOT)/%.cpp.od: $(UNIT_SRC_ROOT)/%.cpp
	$(CC) $(DFLAGS) -D_UNIT_TESTS_ -c $< -o $@ $(INCLUDES) -I$(UNIT_SRC_ROOT)/inc
	
$(OBJ_ROOT)/%.cpp.o: $(UNIT_SRC_ROOT)/%.cpp
	$(CC) $(UTRFLAGS) -D_UNIT_TESTS_ -c $< -o $@ $(INCLUDES) -I$(UNIT_SRC_ROOT)/inc
	
$(OBJ_ROOT)/%.cu.od: $(UNIT_SRC_ROOT)/%.cu
	$(NVCC) $(DNVCCFLAGS) -D_UNIT_TESTS_ -c $< -o $@ $(CUDA_INCLUDES) -I$(UNIT_SRC_ROOT)/inc
	
$(OBJ_ROOT)/%.cu.o: $(UNIT_SRC_ROOT)/%.cu
	$(NVCC) $(RNVCCFLAGS) -D_UNIT_TESTS_ -c $< -o $@ $(CUDA_INCLUDES) -I$(UNIT_SRC_ROOT)/inc

$(UNIT_EXE_D): $(UNIT_OBJS_D)
	$(CC) $(DFLAGS) -D_UNIT_TESTS_ -o $@ \
		$(UNIT_OBJS_D) \
		-Llib \
        $(LIBS_D) $(CUDA_LIBS_D) \
        -laxnetd \
		-lgtest_main -lpthread
	
$(UNIT_EXE): $(UNIT_OBJS)
	$(CC) $(UTRFLAGS) -D_UNIT_TESTS_ -o $@ \
		$(UNIT_OBJS) \
		-Llib \
        $(LIBS) $(CUDA_LIBS) \
		-laxnet \
        -lgtest_main -lpthread

setup:
	mkdir -p obj lib

clean:
	rm -f obj/* lib/* $(TRAINER_EXE_D) $(TRAINER_EXE) $(UNIT_EXE_D) $(UNIT_EXE)
