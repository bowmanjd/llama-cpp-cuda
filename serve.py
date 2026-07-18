import modal

cuda_version = "13.0"
llama_cpp_tag = "b10066"
container_image = f"ghcr.io/bowmanjd/llama-cpp-cuda:{llama_cpp_tag}-cuda{cuda_version}"
hf_hub_cache = "/hub"
model_id = "unsloth/Qwen3.6-27B-MTP-GGUF:UD-Q8_K_XL"

image = (
    modal.Image.from_registry(container_image)
    .entrypoint([])
    .env({"HF_HUB_CACHE": hf_hub_cache})
)

app = modal.App("llama_cpp")
hf_cache_volume = modal.Volume.from_name("hf_hub_llama_cpp", create_if_missing=True)
# llama-server reads the LLAMA_API_KEY env var for bearer token auth.
# Create the secret with: modal secret create llama-api-key LLAMA_API_KEY=<your-key>
llama_api_key = modal.Secret.from_name("llama-api-key")


@app.function(
    image=image,
    gpu="L40S",
    volumes={hf_hub_cache: hf_cache_volume},
    secrets=[llama_api_key],
    timeout=3600,
)
@modal.web_server(port=8000, startup_timeout=600)
def serve():
    import subprocess

    cmd = [
        "llama-server",
        "--host",
        "0.0.0.0",
        "--port",
        "8000",
        "--fa",
        "on",
        "--fitt",
        "0",
        # "--no-mmproj",
        # "true",
        # "--no-mmap",
        # "true",
        "--jinja",
        "--spec-type",
        "draft-mtp",
        # "-ctk",
        # "q8_0",
        # "-ctv",
        # "q8_0",
        "-ub",
        "2048",
        "--temp",
        "0.6",
        "--top-k",
        "20",
        "--min-p",
        "0.0",
        "--top-p",
        "0.95",
        "--presence-penalty",
        "0.0",
        "--repeat-penalty",
        "1.0",
        "-hf",
        model_id,
    ]

    # We use Popen because @modal.web_server monitors the background process
    subprocess.Popen(cmd)


@app.local_entrypoint()
def main():
    # This runs when you type `modal run script.py`
    # It tells Modal to trigger the 'serve' function remotely
    serve.remote()
