#!/usr/bin/env bash
# Source (do not execute): derive the per-run paths and store URLs every component job uses from the
# two variables the templates set (LAB_ENV, STATE_STORAGE_ACCOUNT). Keeps the expanded YAML small.
# No secrets here.
: "${LAB_ENV:?LAB_ENV not set}" "${STATE_STORAGE_ACCOUNT:?STATE_STORAGE_ACCOUNT not set}"
_blob="https://${STATE_STORAGE_ACCOUNT}.blob.core.windows.net"
export CONTRACTS_URL="${CONTRACTS_URL:-$_blob/contracts}"
export PLANS_URL="${PLANS_URL:-$_blob/plans}"
export RECORDS_URL="${RECORDS_URL:-$_blob/deployments}"
export SELECTION_FILE="${SELECTION_FILE:-${PIPELINE_WORKSPACE:-.}/selection/selection.json}"
export ARTIFACT_METADATA_DIR="${ARTIFACT_METADATA_DIR:-${PIPELINE_WORKSPACE:-.}/artifact-metadata}"
export BINDING_FILE="${BINDING_FILE:-${AGENT_TEMPDIRECTORY:-/tmp}/binding.json}"
export MANIFEST_FILE="${MANIFEST_FILE:-${PIPELINE_WORKSPACE:-.}/plan/manifest.json}"
export APPLIED_MARKER="${APPLIED_MARKER:-${AGENT_TEMPDIRECTORY:-/tmp}/applied}"
export OUT_DIR="${OUT_DIR:-${BUILD_ARTIFACTSTAGINGDIRECTORY:-/tmp}/plan}"
unset _blob
