NVCC ?= nvcc
TARGET := fp8_matmul
SRC := fp8_matmul.cu
ARCH ?= sm_89
NVCCFLAGS := -O3 -std=c++14 -lineinfo -arch=$(ARCH)
LDFLAGS := -lcublasLt
ARGS ?= -f e4m3 -m 64 -n 64 -k 64

.PHONY: all run clean help

all: $(TARGET)

$(TARGET): $(SRC)
	$(NVCC) $(NVCCFLAGS) -o $@ $< $(LDFLAGS)

run: $(TARGET)
	./$(TARGET) $(ARGS)

clean:
	rm -f $(TARGET)

help:
	@echo "make               Build fp8_matmul (cuBLASLt Tensor Core)"
	@echo "make run           Run with ARGS='$(ARGS)'"
	@echo "make clean         Remove build artifact"
	@echo ""
	@echo "Usage: ./fp8_matmul [-f e4m3|e5m2] [-m M] [-n N] [-k K]"
	@echo "  (Note: M, N, K must be multiples of 16 for Tensor Core)"
	@echo ""
	@echo "Override ARCH, e.g. make ARCH=sm_90"
	@echo "Default ARCH: sm_89 (Ada, RTX 6000)"
