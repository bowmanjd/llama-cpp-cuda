#!/usr/bin/env python3
"""
serve_baseten.py

A script to programmatically deploy a dedicated llama-server GGUF inference endpoint
to Baseten using custom container mode (no_build: true) via Baseten's REST API.
"""

import os
import sys
import json
import argparse
import tempfile
import tarfile
import time
import urllib.request
import urllib.error
import subprocess
import shutil

# Ensure boto3 is installed
try:
    import boto3
except ImportError:
    print("Error: The 'boto3' library is required to run this script.", file=sys.stderr)
    print("Please install it by running: pip install boto3", file=sys.stderr)
    sys.exit(1)


def parse_arguments(cuda_versions, default_cuda):
    parser = argparse.ArgumentParser(
        description="Deploy llama-server dynamically to Baseten using REST API."
    )
    parser.add_argument(
        "--cuda-version",
        choices=cuda_versions,
        default=default_cuda,
        help=f"Target CUDA version (available: {', '.join(cuda_versions)}). Default: {default_cuda}"
    )
    parser.add_argument(
        "--model-id",
        default="unsloth/gemma-4-31B-it-GGUF:UD-Q5_K_XL",
        help="Hugging Face GGUF model repository and file to download/serve. Default: unsloth/gemma-4-31B-it-GGUF:UD-Q5_K_XL"
    )
    parser.add_argument(
        "--accelerator",
        default=None,
        help="GPU Accelerator type (e.g., A100, A10G, L4, H100). Default: A100"
    )
    parser.add_argument(
        "--instance-type",
        default="A10G:2x24x96",
        help="Specific Baseten instance type SKU (e.g. 'A100:12x144', 'A10Gx8x32', 'L4:4x16'). Overrides accelerator/cpu/memory if set."
    )
    parser.add_argument(
        "--cpu",
        default=None,
        help="Optional CPU allocation (e.g. '4', '8')."
    )
    parser.add_argument(
        "--memory",
        default=None,
        help="Optional memory allocation (e.g. '16Gi', '32Gi')."
    )
    parser.add_argument(
        "--model-name",
        default="llama-cpp-gemma",
        help="Name of the model as registered on Baseten. Default: llama-cpp-gemma"
    )
    parser.add_argument(
        "--skip-polling",
        action="store_true",
        help="Skip polling for deployment to become ACTIVE and applying autoscaling."
    )
    return parser.parse_args()


def load_config():
    config_path = "config.json"
    if not os.path.exists(config_path):
        print(f"Error: Config file '{config_path}' not found in the current directory.", file=sys.stderr)
        sys.exit(1)

    try:
        with open(config_path, "r") as f:
            return json.load(f)
    except Exception as e:
        print(f"Error parsing config.json: {e}", file=sys.stderr)
        sys.exit(1)


def make_request(url, method="GET", headers=None, data=None):
    if headers is None:
        headers = {}

    req_data = None
    if data is not None:
        if isinstance(data, dict):
            req_data = json.dumps(data).encode("utf-8")
            headers["Content-Type"] = "application/json"
        elif isinstance(data, str):
            req_data = data.encode("utf-8")
        else:
            req_data = data

    req = urllib.request.Request(url, method=method, headers=headers, data=req_data)
    try:
        with urllib.request.urlopen(req) as response:
            resp_body = response.read().decode("utf-8")
            if response.status >= 400:
                raise Exception(f"HTTP Error {response.status}: {resp_body}")
            if resp_body:
                return json.loads(resp_body)
            return {}
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8")
        raise Exception(f"HTTP Error {e.code}: {err_body}")
    except Exception as e:
        raise Exception(f"Request failed: {e}")


def get_available_instance_types(api_key):
    headers = {"Authorization": f"Bearer {api_key}"}
    try:
        resp = make_request("https://api.baseten.co/v1/instance_types", headers=headers)
        return resp.get("instance_types", [])
    except Exception as e:
        print(f"Warning: Could not fetch instance types from Baseten API: {e}", file=sys.stderr)
        return []


def main():
    # 1. Parse config.json to resolve container versioning
    config_data = load_config()
    llama_cpp_tag = config_data.get("llamaCppTag")
    cuda_versions_dict = config_data.get("cudaVersions", {})
    cuda_versions = list(cuda_versions_dict.keys())

    if not llama_cpp_tag or not cuda_versions:
        print("Error: config.json is missing required fields ('llamaCppTag' or 'cudaVersions').", file=sys.stderr)
        sys.exit(1)

    default_cuda = "13.0" if "13.0" in cuda_versions else cuda_versions[0]

    # 2. Parse command line arguments
    args = parse_arguments(cuda_versions, default_cuda)

    baseten_api_key = os.environ.get("BASETEN_API_KEY")
    if not baseten_api_key:
        print("Error: BASETEN_API_KEY environment variable is not set.", file=sys.stderr)
        sys.exit(1)

    # Validate requested GPU instance type against Baseten account capabilities
    available_instances = get_available_instance_types(baseten_api_key)
    if available_instances:
        gpu_types = set(it.get("gpu_type") for it in available_instances if it.get("gpu_type"))
        instance_ids = set(it.get("id") for it in available_instances)

        target = args.instance_type or args.accelerator
        if target not in instance_ids and target not in gpu_types:
            print(f"Info: Requested accelerator/instance '{target}' is not listed in standard GET /v1/instance_types pool.", file=sys.stderr)
            print("Standard API GPU types for this key: " + ", ".join(sorted(gpu_types)), file=sys.stderr)



    # Resolve dynamic container tag
    image_tag = f"ghcr.io/bowmanjd/llama-cpp-cuda:{llama_cpp_tag}-cuda{args.cuda_version}"
    print(f"Targeting container tag: {image_tag}")
    print(f"Model ID:                {args.model_id}")
    if args.instance_type:
        print(f"Instance Type:           {args.instance_type}")
    else:
        print(f"Accelerator:             {args.accelerator}")
        if args.cpu:
            print(f"CPU Cores:               {args.cpu}")
        if args.memory:
            print(f"Memory:                  {args.memory}")
    print(f"Baseten Model Name:      {args.model_name}")

    # 3. Build/fetch Nix slim package path
    slug = args.cuda_version.replace(".", "-")
    nix_attr = f".#slim-{slug}"
    print(f"Building/fetching Nix slim package {nix_attr}...")
    try:
        res = subprocess.run(
            ["nix", "build", nix_attr, "--print-out-paths", "--no-link"],
            capture_output=True,
            text=True,
            check=True
        )
        slim_path = res.stdout.strip()
        print(f"Nix slim package path: {slim_path}")
    except subprocess.CalledProcessError as e:
        print(f"Error building Nix package: {e.stderr or e.stdout}", file=sys.stderr)
        sys.exit(1)

    # 4. Create config dictionary (for REST payloads) and generate config.yaml
    resources_dict = {"use_gpu": True}
    resources_yaml_lines = ["  use_gpu: true"]

    if args.instance_type:
        resources_dict["instance_type"] = args.instance_type
        resources_yaml_lines.insert(0, f'  instance_type: "{args.instance_type}"')
    else:
        resources_dict["accelerator"] = args.accelerator
        resources_yaml_lines.insert(0, f'  accelerator: "{args.accelerator}"')
        if args.cpu:
            resources_dict["cpu"] = args.cpu
            resources_yaml_lines.append(f'  cpu: "{args.cpu}"')
        if args.memory:
            resources_dict["memory"] = args.memory
            resources_yaml_lines.append(f'  memory: "{args.memory}"')

    config_dict = {
        "model_name": args.model_name,
        "resources": resources_dict,
        "requirements": [
            "requests",
            "urllib3"
        ],
        "model_metadata": {
            "model_id": args.model_id,
            "tags": [
                "openai-compatible"
            ]
        }
    }

    resources_yaml_str = "\n".join(resources_yaml_lines)
    config_yaml_content = f"""model_name: "{args.model_name}"
resources:
{resources_yaml_str}
requirements:
  - requests
  - urllib3
model_metadata:
  model_id: "{args.model_id}"
  tags:
    - openai-compatible
"""



    model_py_content = """import os
import sys
import subprocess
import time
import requests
import threading

class Model:
    def __init__(self, **kwargs):
        self._config = kwargs.get("config")
        self._secrets = kwargs.get("secrets")
        self._process = None

    def load(self):
        # 1. Locate the packaged binary across potential extraction layouts
        model_dir = os.path.dirname(__file__)
        parent_dir = os.path.dirname(model_dir)
        candidate_bins = [
            os.path.join(model_dir, "bin", "llama-server"),
            os.path.join(model_dir, "llama-server"),
            os.path.join(parent_dir, "bin", "llama-server"),
            "/app/model/bin/llama-server",
            "/app/bin/llama-server"
        ]

        bin_path = None
        for cb in candidate_bins:
            if os.path.isfile(cb):
                bin_path = cb
                break

        if not bin_path:
            raise FileNotFoundError(f"Could not locate llama-server binary in candidate locations: {candidate_bins}")

        print(f"Found llama-server at: {bin_path}")

        # Ensure binary is executable
        try:
            os.chmod(bin_path, 0o755)
        except Exception as e:
            print(f"Warning: Failed to set executable permissions on binary: {e}", file=sys.stderr)

        # 2. Locate dynamic library paths and ELF loader
        lib_paths = [
            os.path.join(model_dir, "lib"),
            os.path.join(parent_dir, "lib"),
            "/app/model/lib",
            "/app/lib"
        ]

        # Locate dynamic loader (ld-linux-x86-64.so.2), prioritizing the bundled loader from Nix
        loader_path = None
        candidate_loaders = [os.path.join(lp, "ld-linux-x86-64.so.2") for lp in lib_paths] + [
            "/lib64/ld-linux-x86-64.so.2",
            "/lib/ld-linux-x86-64.so.2",
            "/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"
        ]

        for cl in candidate_loaders:
            if os.path.isfile(cl):
                loader_path = cl
                break

        # 3. Environment setup: update LD_LIBRARY_PATH
        env = os.environ.copy()
        existing_ld = env.get("LD_LIBRARY_PATH", "")
        all_paths = [lp for lp in lib_paths if os.path.isdir(lp)]
        if existing_ld:
            all_paths.append(existing_ld)

        all_paths.extend(["/usr/lib64", "/usr/lib/x86_64-linux-gnu", "/run/opengl-driver/lib"])
        lib_path_str = ":".join(all_paths)
        env["LD_LIBRARY_PATH"] = lib_path_str
        print(f"Configured LD_LIBRARY_PATH: {lib_path_str}")

        # 4. Retrieve model info from config
        model_metadata = self._config.get("model_metadata", {})
        model_id = model_metadata.get("model_id")
        if not model_id:
            raise ValueError("model_id is not specified in model_metadata of config.yaml")

        # 5. Handle Hugging Face token secret
        hf_token = None
        if self._secrets and "hf_access_token" in self._secrets:
            hf_token = self._secrets["hf_access_token"]
        elif os.path.exists("/secrets/hf_access_token"):
            try:
                with open("/secrets/hf_access_token", "r") as f:
                    hf_token = f.read().strip()
            except Exception:
                pass

        if hf_token:
            env["HF_TOKEN"] = hf_token

        server_args = [
            bin_path,
            "--host", "127.0.0.1",
            "--port", "8000",
            "--jinja",
            "-hf", model_id
        ]

        # 6. Build command: invoke via bundled loader with explicit library path for complete distro isolation
        if loader_path:
            print(f"Invoking llama-server via loader '{loader_path}' with library path '{lib_path_str}'")
            cmd = [loader_path, "--library-path", lib_path_str] + server_args
        else:
            cmd = server_args


        print(f"Starting llama-server: {' '.join(cmd)}")
        self._process = subprocess.Popen(
            cmd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1
        )


        # Stream logs to stdout
        def log_streamer():
            for line in iter(self._process.stdout.readline, ""):
                print(f"[llama-server] {line}", end="", flush=True)
            self._process.stdout.close()
            self._process.wait()
            print(f"[llama-server] Exited with code {self._process.returncode}")

        t = threading.Thread(target=log_streamer, daemon=True)
        t.start()

        # 5. Wait for the server to be healthy
        health_url = "http://127.0.0.1:8000/health"
        start_time = time.time()
        timeout = 900  # 15 minutes to allow for large model download

        print("Waiting for llama-server to start up and download model...")
        while time.time() - start_time < timeout:
            if self._process.poll() is not None:
                raise RuntimeError(f"llama-server exited early with code {self._process.returncode}")
            try:
                resp = requests.get(health_url, timeout=5)
                if resp.status_code == 200:
                    print("llama-server is healthy!")
                    return
            except Exception:
                pass
            time.sleep(5)

        raise TimeoutError("llama-server failed to start within timeout.")

    def predict(self, model_input):
        # Forward the request to llama-server
        url = "http://127.0.0.1:8000/v1/chat/completions"
        stream = model_input.get("stream", False)

        if stream:
            def stream_generator():
                with requests.post(url, json=model_input, stream=True) as r:
                    for chunk in r.iter_content(chunk_size=4096):
                        yield chunk
            return stream_generator()
        else:
            resp = requests.post(url, json=model_input)
            return resp.json()
"""

    # 5. Write Truss files to temporary folder and pack as model.tgz
    with tempfile.TemporaryDirectory() as temp_dir:
        # Create Truss structure
        model_dir = os.path.join(temp_dir, "model")
        os.makedirs(model_dir, exist_ok=True)
        bin_dir = os.path.join(model_dir, "bin")
        os.makedirs(bin_dir, exist_ok=True)
        lib_dir = os.path.join(model_dir, "lib")
        os.makedirs(lib_dir, exist_ok=True)

        config_path = os.path.join(temp_dir, "config.yaml")
        with open(config_path, "w") as f:
            f.write(config_yaml_content)

        with open(os.path.join(model_dir, "__init__.py"), "w") as f:
            f.write("")

        # Write model.py
        model_py_path = os.path.join(model_dir, "model.py")
        with open(model_py_path, "w") as f:
            f.write(model_py_content)

        # Copy llama-server binary
        src_bin = os.path.join(slim_path, "bin", "llama-server")
        dest_bin = os.path.join(bin_dir, "llama-server")
        print("Copying llama-server binary...")
        shutil.copy2(src_bin, dest_bin)

        # Copy lib/*.so*
        src_lib_dir = os.path.join(slim_path, "lib")
        print("Copying shared libraries...")
        for item in os.listdir(src_lib_dir):
            s = os.path.join(src_lib_dir, item)
            d = os.path.join(lib_dir, item)
            if os.path.islink(s):
                linkto = os.readlink(s)
                os.symlink(linkto, d)
            elif os.path.isfile(s):
                shutil.copy2(s, d)

        # Package the model archive
        archive_path = os.path.join(temp_dir, "model.tgz")
        print("Packaging Truss configuration and files...")
        with tarfile.open(archive_path, "w:gz") as tar:
            tar.add(config_path, arcname="config.yaml")
            tar.add(model_dir, arcname="model")

        # 6. Call Baseten REST API - Prepare Model Upload
        headers = {
            "Authorization": f"Bearer {baseten_api_key}",
            "Content-Type": "application/json"
        }

        prepare_payload = {
            "name": args.model_name,
            "deployment": {
                "config": config_dict
            }
        }

        print("Preparing model upload with Baseten...")
        prepare_resp = make_request(
            "https://api.baseten.co/v1/prepare_model_upload",
            method="POST",
            headers=headers,
            data=prepare_payload
        )

        creds = prepare_resp["creds"]
        s3_bucket = prepare_resp["s3_bucket"]
        s3_key = prepare_resp["s3_key"]
        s3_region = prepare_resp["s3_region"]

        # 7. Upload to AWS S3 using boto3 with temporary credentials
        print("Uploading archive to S3 bucket...")
        session = boto3.Session(
            aws_access_key_id=creds["aws_access_key_id"],
            aws_secret_access_key=creds["aws_secret_access_key"],
            aws_session_token=creds["aws_session_token"],
            region_name=s3_region,
        )
        s3_client = session.client("s3")
        s3_client.upload_file(archive_path, s3_bucket, s3_key)
        print("S3 Upload complete.")

        # 8. Commit Model via POST /v1/models
        create_payload = {
            "source": {
                "kind": "model_archive",
                "name": args.model_name,
                "s3_key": s3_key,
                "deployment": {
                    "config": config_dict
                }
            }
        }

        print("Committing model to Baseten...")
        create_resp = make_request(
            "https://api.baseten.co/v1/models",
            method="POST",
            headers=headers,
            data=create_payload
        )

        model_id = create_resp["model"]["id"]
        deployment_id = create_resp["deployment"]["id"]
        print(f"Model successfully committed! Model ID: {model_id}, Deployment ID: {deployment_id}")

    if args.skip_polling:
        print("Skipping polling step as requested.")
        return

    # 8. Poll Deployment status
    print("Waiting for deployment to become ACTIVE...")
    start_time = time.time()

    while True:
        status_url = f"https://api.baseten.co/v1/models/{model_id}/deployments/{deployment_id}"
        try:
            status_resp = make_request(status_url, headers={"Authorization": f"Bearer {baseten_api_key}"})
            status = status_resp.get("status")
        except Exception as e:
            print(f"\nWarning: Failed to fetch status: {e}. Retrying...", file=sys.stderr)
            time.sleep(15)
            continue

        elapsed = int(time.time() - start_time)
        print(f"\rCurrent status: {status} (elapsed: {elapsed}s)", end="", flush=True)

        if status == "ACTIVE":
            print("\nDeployment is now ACTIVE!")
            break
        elif status in ("FAILED", "ERROR", "INACTIVE", "DEACTIVATED"):
            print(f"\nError: Deployment failed with status '{status}'")
            print(json.dumps(status_resp, indent=2))
            sys.exit(1)

        time.sleep(15)

    # 9. Apply Autoscaling settings (Scale-to-Zero)
    print("Applying autoscaling settings (scale-to-zero)...")
    autoscaling_url = f"https://api.baseten.co/v1/models/{model_id}/deployments/{deployment_id}/autoscaling_settings"
    autoscaling_payload = {
        "min_replica": 0,
        "max_replica": 4,
        "scale_down_delay": 900
    }

    try:
        autoscaling_resp = make_request(
            autoscaling_url,
            method="PATCH",
            headers=headers,
            data=autoscaling_payload
        )
        print("Autoscaling settings updated successfully:")
        print(json.dumps(autoscaling_resp, indent=2))
    except Exception as e:
        print(f"Error applying autoscaling settings: {e}", file=sys.stderr)
        sys.exit(1)

    print("\nDeployment process completed successfully!")


if __name__ == "__main__":
    main()
