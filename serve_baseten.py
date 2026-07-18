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
        default="L40S",
        help="GPU Accelerator type. Default: L40S"
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

    # Resolve dynamic container tag
    image_tag = f"ghcr.io/bowmanjd/llama-cpp-cuda:{llama_cpp_tag}-cuda{args.cuda_version}"
    print(f"Targeting container tag: {image_tag}")
    print(f"Model ID:                {args.model_id}")
    print(f"Accelerator:             {args.accelerator}")
    print(f"Baseten Model Name:      {args.model_name}")

    # 3. Create config dictionary (for REST payloads) and generate config.yaml
    config_dict = {
        "model_name": args.model_name,
        "base_image": {
            "image": image_tag
        },
        "docker_server": {
            "no_build": True,
            "start_command": f"llama-server --host 0.0.0.0 --port 8000 --jinja -hf {args.model_id}",
            "server_port": 8000,
            "predict_endpoint": "/v1/chat/completions",
            "readiness_endpoint": "/health",
            "liveness_endpoint": "/health"
        },
        "resources": {
            "accelerator": args.accelerator,
            "use_gpu": True
        }
    }

    # Generate config.yaml content
    config_yaml_content = f"""model_name: "{args.model_name}"
base_image:
  image: "{image_tag}"
docker_server:
  no_build: true
  start_command: >-
    llama-server
    --host 0.0.0.0
    --port 8000
    --jinja
    -hf {args.model_id}
  server_port: 8000
  predict_endpoint: /v1/chat/completions
  readiness_endpoint: /health
  liveness_endpoint: /health
resources:
  accelerator: "{args.accelerator}"
  use_gpu: true
"""

    # 4. Write config.yaml to temporary folder and pack as model.tgz
    with tempfile.TemporaryDirectory() as temp_dir:
        config_path = os.path.join(temp_dir, "config.yaml")
        with open(config_path, "w") as f:
            f.write(config_yaml_content)
        
        archive_path = os.path.join(temp_dir, "model.tgz")
        print("Packaging Truss configuration...")
        with tarfile.open(archive_path, "w:gz") as tar:
            tar.add(config_path, arcname="config.yaml")

        # 5. Call Baseten REST API - Prepare Model Upload
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
        
        # 6. Upload to AWS S3 using boto3 with temporary credentials
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
        
        # 7. Commit Model via POST /v1/models
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
