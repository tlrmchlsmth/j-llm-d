"""JIT-compile the mla_rope_quant CUDA kernel as a standalone extension.

Compiles only mla_rope_quant.cu (+ kernel header) via nvcc, avoiding a
full cmake rebuild of all 98 vLLM CUDA sources.  The resulting module is
cached by torch so subsequent imports are instant.

Usage (from /opt/vllm-source):
    python tools/jit_mla_rope_quant.py
"""
import os
import textwrap

from torch.utils.cpp_extension import load

SRC_DIR = "/opt/vllm-source/csrc"
BUILD_DIR = "/tmp/jit_build/mla_rope_quant"
os.makedirs(BUILD_DIR, exist_ok=True)

# Normalize arch list — torch JIT doesn't understand "10.0f" (cmake-only syntax)
arch = os.environ.get("TORCH_CUDA_ARCH_LIST", "")
if arch:
    os.environ["TORCH_CUDA_ARCH_LIST"] = "10.0a"

# Minimal pybind11 binding — forward-declares the function defined in
# mla_rope_quant.cu and exposes it to Python.
BINDING_SRC = textwrap.dedent("""\
    #include <torch/extension.h>

    void mla_rope_quantize_fp8(
        torch::Tensor&, torch::Tensor&, torch::Tensor&, torch::Tensor&,
        torch::Tensor&, torch::Tensor&, torch::Tensor&, torch::Tensor&,
        torch::Tensor&, torch::Tensor&,
        double, double, bool, bool);

    void mla_rope_quantize_fp8_fused_cache(
        torch::Tensor&, torch::Tensor&, torch::Tensor&, torch::Tensor&,
        torch::Tensor&, torch::Tensor&, torch::Tensor&, torch::Tensor&,
        torch::Tensor&, torch::Tensor&,
        double, double, bool, bool);

    void mla_fused_cache_rope(
        torch::Tensor&, torch::Tensor&, torch::Tensor&,
        torch::Tensor&, torch::Tensor&, torch::Tensor&, torch::Tensor&,
        int64_t, int64_t,
        double, double, bool);

    void mla_fused_cache_nope(
        torch::Tensor&, torch::Tensor&, torch::Tensor&,
        torch::Tensor&, torch::Tensor&,
        int64_t, double, double);

    PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
        m.def("mla_rope_quantize_fp8", &mla_rope_quantize_fp8,
              "Fused RoPE + FP8 quantization for MLA decode");
        m.def("mla_rope_quantize_fp8_fused_cache",
              &mla_rope_quantize_fp8_fused_cache,
              "Fused RoPE + FP8 quant + KV cache scatter-write");
        m.def("mla_fused_cache_rope", &mla_fused_cache_rope,
              "Split rope kernel for dual-stream overlap");
        m.def("mla_fused_cache_nope", &mla_fused_cache_nope,
              "Split nope kernel for dual-stream overlap");
    }
""")

binding_path = os.path.join(SRC_DIR, "mla_rope_quant_binding.cpp")
with open(binding_path, "w") as f:
    f.write(BINDING_SRC)

mod = load(
    name="mla_rope_quant_ext",
    sources=[
        binding_path,
        os.path.join(SRC_DIR, "mla_rope_quant.cu"),
    ],
    extra_include_paths=[SRC_DIR],
    build_directory=BUILD_DIR,
    extra_cflags=["-O3"],
    extra_cuda_cflags=[
        "-O3",
        "--use_fast_math",
    ],
    verbose=True,
)

print(f"mla_rope_quant_ext built: {mod}")
