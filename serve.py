import modal

cuda_version = "13.0"
llama_cpp_tag = "b8793"
container_image = f"ghcr.io/bowmanjd/llama-cpp-cuda:{llama_cpp_tag}-cuda{cuda_version}"
hf_hub_cache = "/hub"
# model_id = "Jackrong/Qwopus3.5-27B-v3-GGUF:Q5_K_M"
model_id = "Jackrong/Qwopus3.5-4B-v3-GGUF:Q5_K_M"

image = (
    modal.Image.from_registry(container_image)
    .entrypoint([])
    .env({"HF_HUB_CACHE": hf_hub_cache})
)

app = modal.App("llama_cpp_qwopus")
hf_cache_volume = modal.Volume.from_name("hf_hub_llama_cpp", create_if_missing=True)


@app.function(
    image=image,
    gpu="A10",
    volumes={hf_hub_cache: hf_cache_volume},
    timeout=3600,
)
@modal.web_server(port=8000, startup_timeout=600)
def serve():
    import os
    import subprocess

    cmd = [
        "llama-server",
        "--host",
        "0.0.0.0",
        "--port",
        "8000",
		"-hf",
		model_id
    ]

    # We use Popen because @modal.web_server monitors the background process
    subprocess.Popen(cmd)


@app.local_entrypoint()
def main():
    # This runs when you type `modal run script.py`
    # It tells Modal to trigger the 'serve' function remotely
    serve.remote()
