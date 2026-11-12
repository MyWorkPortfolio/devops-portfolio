#!/usr/bin/env bash
# access-check.sh - read-only AWS access diagnostic
#
# Answers two questions about the current AWS identity:
#   1. Which services can I reach in this region?
#   2. When I'm denied, WHAT denied me? (IAM policy, Organizations SCP,
#      permissions boundary, a region lock, or a login problem)
#
# It only calls list/describe APIs. It never creates, changes or deletes anything.

set -uo pipefail

VERSION="2.0.0"
REGION=""
SCAN=false
MASK=false
PASS=0
FAIL=0
SCP_HITS=0

usage() {
  cat <<EOF
access-check.sh v$VERSION - read-only AWS access diagnostic

Usage: $(basename "$0") [-r REGION] [-s] [-m] [-h]

  -r REGION   Region to test (default: \$AWS_REGION, then profile region, then us-east-1)
  -s          Also probe every enabled region to find region locks
  -m          Mask account IDs and session names (safe for screenshots and READMEs)
  -h          Show this help

Exit codes:
  0  every check passed
  1  not authenticated, or AWS CLI missing
  2  one or more checks were denied or failed
EOF
}

while getopts ":r:smh" opt; do
  case $opt in
    r) REGION=$OPTARG ;;
    s) SCAN=true ;;
    m) MASK=true ;;
    h) usage; exit 0 ;;
    :) echo "Option -$OPTARG needs a value" >&2; exit 64 ;;
    *) echo "Unknown option: -$OPTARG" >&2; usage >&2; exit 64 ;;
  esac
done

# Colours only when writing to a terminal, so piped output stays clean
if [[ -t 1 ]]; then
  GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  GREEN=""; RED=""; YELLOW=""; BOLD=""; RESET=""
fi

command -v aws >/dev/null 2>&1 || { echo "AWS CLI not found. Install AWS CLI v2 first." >&2; exit 1; }

REGION="${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null)}}}"
REGION="${REGION:-us-east-1}"

# Hide 12-digit account IDs and the session name when -m is set
sanitize() {
  if $MASK; then
    sed -E 's/[0-9]{12}/************/g; s#(assumed-role/[^/]+/)[^ ]+#\1<session>#g'
  else
    cat
  fi
}

# Turn an AWS error message into the reason for the failure
classify() {
  local e=$1
  if   grep -qi "CreateOAuth2Token" <<<"$e";                 then echo LOGIN
  elif grep -qi "service control policy" <<<"$e";            then echo SCP
  elif grep -qi "resource control policy" <<<"$e";           then echo RCP
  elif grep -qi "permissions boundary" <<<"$e";              then echo BOUNDARY
  elif grep -qi "session policy" <<<"$e";                    then echo SESSION
  elif grep -qiE "AccessDenied|UnauthorizedOperation|not authorized|AuthorizationError" <<<"$e"; then echo IAM
  elif grep -qiE "OptInRequired|SubscriptionRequired|not enabled|not supported" <<<"$e"; then echo DISABLED
  elif grep -qiE "Could not connect|EndpointConnectionError|timed out" <<<"$e"; then echo NETWORK
  else echo ERROR
  fi
}

explain() {
  case $1 in
    LOGIN)    echo "login can't refresh here - run 'aws login' with your project's home region" ;;
    SCP)      echo "blocked by an Organizations service control policy (overrides your IAM allow)" ;;
    RCP)      echo "blocked by a resource control policy" ;;
    BOUNDARY) echo "blocked by a permissions boundary on your role" ;;
    SESSION)  echo "blocked by a session policy" ;;
    IAM)      echo "your IAM policies don't allow this" ;;
    DISABLED) echo "service not enabled for this account or region" ;;
    NETWORK)  echo "could not reach the AWS endpoint" ;;
    *)        echo "unexpected error" ;;
  esac
}

check() {
  local label=$1; shift
  local err kind
  if err=$(aws "$@" --region "$REGION" 2>&1 >/dev/null); then
    printf "  %s%-9s%s %s\n" "$GREEN" "OK" "$RESET" "$label"
    PASS=$((PASS + 1))
  else
    kind=$(classify "$err")
    printf "  %s%-9s%s %-27s %s\n" "$RED" "$kind" "$RESET" "$label" "$(explain "$kind")"
    FAIL=$((FAIL + 1))
    [[ $kind == SCP ]] && SCP_HITS=$((SCP_HITS + 1))
    if [[ $kind == ERROR ]]; then
      printf "            %s\n" "$(head -c 160 <<<"$err" | tr '\n' ' ' | sanitize)"
    fi
  fi
}

scan_regions() {
  local regions r err kind usable=()
  echo
  echo "${BOLD}=========== REGION SCAN (probe: ec2:DescribeVpcs) ===========${RESET}"
  regions=$(aws ec2 describe-regions --region "$REGION" \
              --query 'Regions[].RegionName' --output text 2>/dev/null | tr '\t' '\n' | sort)
  if [[ -z $regions ]]; then
    echo "  (couldn't list regions from $REGION - falling back to a default list)"
    regions="us-east-1 us-east-2 us-west-1 us-west-2 eu-west-1 eu-west-2 eu-west-3 eu-central-1 eu-north-1 ap-south-1 ca-central-1"
  fi
  for r in $regions; do
    if err=$(aws ec2 describe-vpcs --region "$r" --max-items 1 2>&1 >/dev/null); then
      printf "  %s%-9s%s %s\n" "$GREEN" "OK" "$RESET" "$r"
      usable+=("$r")
    else
      kind=$(classify "$err")
      printf "  %s%-9s%s %s\n" "$RED" "$kind" "$RESET" "$r"
    fi
  done
  echo
  echo "  Usable region(s): ${BOLD}${usable[*]:-none}${RESET}"
}

# ---------------------------------------------------------------- identity
echo "${BOLD}================ IDENTITY ================${RESET}"
if ! ID_OUT=$(aws sts get-caller-identity --region "$REGION" --query '[Account,Arn]' --output text 2>&1); then
  printf "%sNot authenticated.%s %s\n" "$RED" "$RESET" "$(explain "$(classify "$ID_OUT")")" >&2
  head -c 300 <<<"$ID_OUT" | sanitize >&2; echo >&2
  echo "Hint: run 'aws login' (or 'aws sso login') and try again." >&2
  exit 1
fi
read -r ACCOUNT ARN <<<"$ID_OUT"
echo "  Account: $(sanitize <<<"$ACCOUNT")"
echo "  Caller:  $(sanitize <<<"$ARN")"
echo "  Region:  $REGION"

if [[ $ARN == *assumed-role/* ]]; then
  ROLE=$(cut -d/ -f2 <<<"$ARN")
  POLICIES=$(aws iam list-attached-role-policies --role-name "$ROLE" \
               --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null)
  [[ -n $POLICIES ]] || POLICIES="(not readable - that is fine)"
  echo "  Role policies: $POLICIES"
fi

# ---------------------------------------------------------------- services
echo
echo "${BOLD}=========== SERVICE ACCESS in $REGION (read-only) ===========${RESET}"
check "EC2 (servers)"            ec2 describe-instances --max-items 1
check "VPC (networking)"         ec2 describe-vpcs --max-items 1
check "S3 (storage)"             s3api list-buckets
check "IAM (permissions)"        iam list-roles --max-items 1
check "Lambda (serverless)"      lambda list-functions --max-items 1
check "ECR (container registry)" ecr describe-repositories --max-items 1
check "ECS (containers)"         ecs list-clusters --max-items 1
check "EKS (Kubernetes)"         eks list-clusters --max-items 1
check "CloudFormation (IaC)"     cloudformation list-stacks --max-items 1
check "CloudWatch (metrics)"     cloudwatch describe-alarms --max-items 1
check "CloudWatch Logs"          logs describe-log-groups --max-items 1
check "DynamoDB (database)"      dynamodb list-tables --max-items 1
check "Route 53 (DNS)"           route53 list-hosted-zones --max-items 1
check "SSM (server management)"  ssm describe-instance-information --max-items 1
check "Secrets Manager"          secretsmanager list-secrets --max-items 1
check "Bedrock (AI models)"      bedrock list-foundation-models --by-provider amazon
check "Budgets (cost alerts)"    budgets describe-budgets --account-id "$ACCOUNT"

$SCAN && scan_regions

# ---------------------------------------------------------------- summary
echo
echo "${BOLD}Summary:${RESET} $PASS passed, $FAIL denied/failed in $REGION"
if (( SCP_HITS > 0 )); then
  echo "${YELLOW}Hint:${RESET} $SCP_HITS check(s) were blocked by an SCP. If regional services fail"
  echo "      but global ones (IAM, S3, Route 53) pass, the SCP is probably a region lock."
  $SCAN || echo "      Run again with -s to find the region(s) you're allowed to use."
fi
echo "Note: OK means you can VIEW a service. Creating resources can still be limited."

(( FAIL == 0 )) || exit 2
