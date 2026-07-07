#!/usr/bin/env bash
#
# Local AWS integration for the Hello app against LocalStack (S3 / SQS / SSM /
# DynamoDB) + a Postgres container — no real AWS account needed.
#
# It boots the stack, provisions the resources, builds the Hello Lambda with the host
# toolchain, and drives a handful of routes THROUGH the Lambda binary via a mock
# Runtime API (support/lambda-mock-runtime.mjs). Every AWS call the app makes is
# redirected to LocalStack through AWS_ENDPOINT_URL, so the S3/SQS/SSM/DynamoDB
# adapters are exercised over the wire.
#
# SKIPS cleanly (exit 0) when docker / node / the aws CLI aren't available, like the
# wasm gates.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELLO="$REPO/Fixtures/Hello"
COMPOSE="$HELLO/docker-compose.localstack.yml"
ENDPOINT="http://localhost:4566"

export AWS_ENDPOINT_URL="$ENDPOINT"
export AWS_REGION="us-east-1"
export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export KV_TABLE="app_kv"
export CACHE_TABLE="app_cache"
export S3_BUCKET="app-storage"
export SQS_URL="$ENDPOINT/000000000000/app-jobs"
export DATABASE_URL="host=localhost port=5432 dbname=app user=app password=app"

skip() { echo "==> SKIPPED ($1)"; exit 0; }
command -v docker >/dev/null 2>&1 || skip "docker not found"
command -v node   >/dev/null 2>&1 || skip "node not found (used for the mock runtime)"
if command -v awslocal >/dev/null 2>&1; then AWS="awslocal"
elif command -v aws  >/dev/null 2>&1; then AWS="aws --endpoint-url=$ENDPOINT"
else skip "neither awslocal nor the aws CLI is installed"; fi

cleanup() { docker compose -f "$COMPOSE" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Booting LocalStack + Postgres"
docker compose -f "$COMPOSE" up -d

echo "==> Waiting for LocalStack"
for _ in $(seq 1 60); do
  curl -sf "$ENDPOINT/_localstack/health" >/dev/null 2>&1 && break; sleep 1
done
echo "==> Waiting for Postgres"
for _ in $(seq 1 60); do
  docker compose -f "$COMPOSE" exec -T postgres pg_isready -U app >/dev/null 2>&1 && break; sleep 1
done

echo "==> Provisioning resources"
$AWS s3 mb "s3://$S3_BUCKET" >/dev/null 2>&1 || true
$AWS sqs create-queue --queue-name app-jobs >/dev/null 2>&1 || true
$AWS ssm put-parameter --name GREETING --value "hello-from-ssm" --type String --overwrite >/dev/null 2>&1 || true
for table in "$KV_TABLE" "$CACHE_TABLE"; do
  $AWS dynamodb create-table --table-name "$table" \
    --attribute-definitions AttributeName=pk,AttributeType=S \
    --key-schema AttributeName=pk,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null 2>&1 || true
done

echo "==> Building the Hello Lambda (host toolchain)"
swift build --package-path "$HELLO" --product Lambda >/dev/null
LAMBDA_BIN="$(swift build --package-path "$HELLO" --product Lambda --show-bin-path)/Lambda"

echo "==> Driving routes through the Lambda binary (mock Runtime API → LocalStack)"
node "$REPO/support/lambda-mock-runtime.mjs" "$LAMBDA_BIN"

echo "GATE PASSED: the Hello Lambda served its routes against LocalStack."
