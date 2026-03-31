#!/bin/bash
# =============================================================================
#  CloudTask — AWS-Integrated Terminal Task Manager
#  Version: 1.0.0
#  Author:  Oyekanmi Lekan
#  GitHub:  github.com/intellisensecodez/cloudtask
#
#  Description:
#    A production-grade, terminal-based task management system for developers
#    and DevOps engineers. Tasks are stored locally AND backed up to AWS S3.
#    Notifications are sent via AWS SNS. All activity is shipped to AWS
#    CloudWatch Logs for audit and observability.
#
#  AWS Services Used:
#    - S3        : Remote backup & restore of tasks.csv
#    - SNS       : Desktop/email alerts for high-priority tasks
#    - CloudWatch: Centralised log shipping & metrics
#
#  Prerequisites:
#    - Bash >= 4.0
#    - AWS CLI v2 configured (aws configure)
#    - IAM permissions: s3:*, sns:Publish, logs:* etc
#
#  Usage:
#    chmod +x cloudtask.sh
#    ./cloudtask.sh            # Launch interactive menu
#    ./cloudtask.sh --help     # Print usage guide
#    ./cloudtask.sh add        # Directly open Add Task prompt
#    ./cloudtask.sh list       # Print all tasks and exit
# =============================================================================

set -euo pipefail   # Exit on error, unset variable, or pipe failure
IFS=$'\n\t'         # Safer word splitting


# =============================================================================
#  CONFIGURATION
# =============================================================================

readonly APP_NAME="CloudTask"
readonly APP_VERSION="1.0.0"

# Local storage
readonly DATA_DIR="${HOME}/.cloudtask"
readonly TASKS_FILE="${DATA_DIR}/tasks.csv"
readonly LOG_FILE="${DATA_DIR}/cloudtask.log"
readonly BACKUP_DIR="${DATA_DIR}/backups"
readonly LOCK_FILE="${DATA_DIR}/cloudtask.lock"

# AWS configuration 
readonly AWS_REGION="${AWS_REGION}"
readonly S3_BUCKET="${S3_BUCKET}"                   
readonly SNS_TOPIC_ARN="${SNS_TOPIC_ARN}"        
readonly CW_LOG_GROUP="${CW_LOG_GROUP}"
readonly CW_LOG_STREAM="${CW_LOG_STREAM:-$(date +"%Y-%m-%d")}" # Set a default log stream name based on current date


# CSV columns 
readonly CSV_HEADER="ID,Name,Description,Category,Priority,DueDate,Status,CreatedAt,UpdatedAt,CompletedAt"

# Pagination
readonly PAGE_SIZE=15


# =============================================================================
#  COLOUR PALETTE
# =============================================================================

readonly RED=$'\033[0;31m'    
readonly BOLD_RED=$'\033[1;31m'
readonly GREEN=$'\033[0;32m'
readonly BOLD_GREEN=$'\033[1;32m'
readonly YELLOW=$'\033[1;33m'
readonly BLUE=$'\033[0;34m'
readonly BOLD_BLUE=$'\033[1;34m'
readonly CYAN=$'\033[0;36m'
readonly BOLD_CYAN=$'\033[1;36m'
readonly MAGENTA=$'\033[0;35m'
readonly WHITE=$'\033[0;37m'
readonly BOLD_WHITE=$'\033[1;37m'
readonly DIM=$'\033[2m'
readonly RESET=$'\033[0m'

# =============================================================================
#  OUTPUT HELPERS
# =============================================================================

print_line() { echo -e "${DIM}$(printf '─%.0s' {1..120})${RESET}"; }
print_dline() { echo -e "${BOLD_BLUE}$(printf '═%.0s' {1..120})${RESET}"; }
blank() { echo ""; }

success() { echo -e "${BOLD_GREEN}  ✔  $*${RESET}"; }
error_msg() { echo -e "${BOLD_RED}  ✘  $*${RESET}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
info() { echo -e "${CYAN}  ℹ  $*${RESET}"; }

die() {
  error_msg "$*"
  log "FATAL" "$*"
  exit 1
}

# =============================================================================
#  UTILITY
# =============================================================================

_press_enter() {
  blank
  read -rp "  Press [Enter] to return to menu..."
}

# =============================================================================
#  HELP
# =============================================================================

print_help() {
cat <<EOF

${BOLD_CYAN}${APP_NAME} v${APP_VERSION}${RESET}
An AWS-Integrated Terminal Task Manager

${BOLD_WHITE}USAGE:${RESET}
./cloudtask.sh              Launch interactive menu
./cloudtask.sh add          Go directly to Add Task
./cloudtask.sh list         Print all tasks and exit
./cloudtask.sh --help       Show this help message

${BOLD_WHITE}AWS ENVIRONMENT VARIABLES:${RESET}
AWS_REGION          AWS region (default: us-west-1)
S3_BUCKET           S3 bucket name for backups
SNS_TOPIC_ARN       SNS topic ARN for HIGH priority alerts
CW_LOG_GROUP        CloudWatch log group name

${BOLD_WHITE}EXAMPLE:${RESET}
export S3_BUCKET=my-tasks-backup
export SNS_TOPIC_ARN=arn:aws:sns:us-east-1:123456789012:task-alerts
./cloudtask.sh

${BOLD_WHITE}DATA LOCATION:${RESET}
Tasks  : ${TASKS_FILE}
Logs   : ${LOG_FILE}
Backups: ${BACKUP_DIR}

EOF
}


# =============================================================================
#  LOGGING
# =============================================================================

# log LEVEL "message"
log() {
  local level="$1"
  local message="$2"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local entry="[${timestamp}] [${level}] ${message}"

  # Write to local log
  echo "${entry}" >> "${LOG_FILE}"

  # Ship to CloudWatch if configured
  if [[ -n "${CW_LOG_GROUP}" ]] && command -v aws &>/dev/null; then
    ship_to_cloudwatch "${entry}" &   # Non-blocking background job
  fi
}

ship_to_cloudwatch() {
  local message="$1"
  local ts=$(date +%s%3N)

  # Check if log stream exists
  if ! aws logs describe-log-streams \
    --log-group-name "${CW_LOG_GROUP}" \
    --log-stream-name-prefix "${CW_LOG_STREAM}" \
    --region "${AWS_REGION}" \
    --query "logStreams[?logStreamName=='${CW_LOG_STREAM}']" \
    --output text | grep -q "${CW_LOG_STREAM}"; then
    
    echo "Creating log stream: ${CW_LOG_STREAM}"
    aws logs create-log-stream \
        --log-group-name "${CW_LOG_GROUP}" \
        --log-stream-name "${CW_LOG_STREAM}" \
        --region "${AWS_REGION}"
  fi

  # CloudWatch shipping 
  aws logs put-log-events \
    --log-group-name  "${CW_LOG_GROUP}" \
    --log-stream-name "${CW_LOG_STREAM}" \
    --log-events "[{\"timestamp\":$ts,\"message\":\"$message\"}]" \
    --region "${AWS_REGION}" \
    --no-cli-pager >/dev/null || true
}


# =============================================================================
#  VALIDATION FUNCTIONS
# =============================================================================

validate_date() {
  local d="$1"
  # Must match YYYY-MM-DD
  if [[ ! "${d}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    return 1
  fi
  # Verify it's a real calendar date
  date -d "${d}" >/dev/null 2>&1
}

validate_priority() {
  [[ "$1" =~ ^(HIGH|MEDIUM|LOW)$ ]]
}

validate_not_empty() {
  [[ -n "${1// /}" ]]
}

validate_id_exists() {
  local id="$1"
  grep -q "^${id}," "${TASKS_FILE}" 2>/dev/null
}


# =============================================================================
#  ID GENERATION
# =============================================================================

get_next_id() {
  # Count data lines (excluding header) and add 1
  local count
  count=$(tail -n +2 "${TASKS_FILE}" | wc -l)
  printf "%03d" $((count + 1))
}

# =============================================================================
#  COMPACT LIST (used internally by update/delete/complete)
# =============================================================================

list_tasks_compact() {

  if [[ ! -s "${TASKS_FILE}" ]]; then return; fi

  echo -e "  ${DIM}"
  printf "  %-5s %-10s %-28s %-8s %-10s\n" "ID" "NAME" "DESCRIPTION" "PRIORITY" "STATUS"
  print_line

  while IFS=',' read -r id name desc cat pri due status rest; do
    [[ "${id}" == "ID" ]] && continue
    printf "  %-5s %-10s %-28s %-8s %-10s\n" "${id}" "${name}" "${desc:0:26}" "${pri}" "${status}"
  done < "${TASKS_FILE}"

  echo -e "${RESET}"
  print_line
  blank
}


# =============================================================================
#  BOOTSTRAP — Create directories and files on first run
# =============================================================================

bootstrap() {
  mkdir -p "${DATA_DIR}" "${BACKUP_DIR}"
  chmod 700 "${DATA_DIR}"

  log "INFO" "Created data directory"

  # Create tasks file with header if it doesn't exist
  if [[ ! -f "${TASKS_FILE}" ]]; then
    echo "${CSV_HEADER}" > "${TASKS_FILE}"
    chmod 600 "${TASKS_FILE}"

    log "INFO" "Created tasks file with headers"
  fi

  # Create log file if it doesn't exist
  if [[ ! -f "${LOG_FILE}" ]]; then
    touch "${LOG_FILE}"
    chmod 600 "${LOG_FILE}"

    log "INFO" "Created log file"
  fi
}

# =============================================================================
#  LOCKING — Prevent concurrent script runs corrupting the data file
# =============================================================================

acquire_lock() {
  if [[ -f "${LOCK_FILE}" ]]; then
    local pid
    pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "unknown")
    die "Another instance is running (PID: ${pid}). If this is wrong, delete ${LOCK_FILE}"
  fi
  echo $$ > "${LOCK_FILE}"
}

release_lock() {
  rm -f "${LOCK_FILE}"
}

# Always release lock on exit (normal or error)
trap release_lock EXIT


# =============================================================================
#  AWS HELPERS
# =============================================================================

aws_available() {
  command -v aws &>/dev/null && [[ -n "${S3_BUCKET}" ]]
}

sns_available() {
  command -v aws &>/dev/null && [[ -n "${SNS_TOPIC_ARN}" ]]
}

# Upload tasks.csv to S3
s3_backup() {
  if aws_available; then
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local s3_key="backups/tasks_${timestamp}.csv"

    info "Backing up to s3://${S3_BUCKET}/${s3_key} ..."

    if aws s3 cp "${TASKS_FILE}" "s3://${S3_BUCKET}/${s3_key}" \
        --region "${AWS_REGION}" \
        --no-cli-pager 2>/dev/null; then
      success "Backup uploaded to S3"
      log "INFO" "S3 backup successful: s3://${S3_BUCKET}/${s3_key}"
    else
      warn "S3 backup failed — tasks saved locally only"
      log "WARN" "S3 backup failed"
    fi
  else
    # Save a local backup instead
    local ts; ts=$(date '+%Y%m%d_%H%M%S')
    cp "${TASKS_FILE}" "${BACKUP_DIR}/tasks_${ts}.csv"
    success "Local backup saved to ${BACKUP_DIR}/tasks_${ts}.csv"
    log "INFO" "Local backup saved: ${BACKUP_DIR}/tasks_${ts}.csv"
  fi
}

# Restore tasks.csv from the latest S3 backup
s3_restore() {
  if ! aws_available; then
    error_msg "AWS CLI or S3_BUCKET not configured. Cannot restore."
    return 1
  fi

  info "Fetching latest backup from S3..."

  local latest_key
  latest_key=$(aws s3 ls "s3://${S3_BUCKET}/backups/" \
    --region "${AWS_REGION}" \
    --no-cli-pager 2>/dev/null \
    | sort | tail -1 | awk '{print $4}')

  if [[ -z "${latest_key}" ]]; then
    error_msg "No backups found in s3://${S3_BUCKET}/backups/"
    return 1
  fi

  # Make a local safety copy before overwriting
  cp "${TASKS_FILE}" "${BACKUP_DIR}/tasks_pre_restore_$(date +%s).csv"

  if aws s3 cp "s3://${S3_BUCKET}/backups/${latest_key}" "${TASKS_FILE}" \
      --region "${AWS_REGION}" \
      --no-cli-pager 2>/dev/null; then
    success "Restored from: ${latest_key}"
    log "INFO" "S3 restore completed: ${latest_key}"
  else
    die "Restore failed. Pre-restore backup saved in ${BACKUP_DIR}"
  fi
}

# Send SNS alert for high-priority tasks
sns_notify() {
  local subject="$1"
  local message="$2"

  if sns_available; then
    aws sns publish \
      --topic-arn  "${SNS_TOPIC_ARN}" \
      --subject    "${subject}" \
      --message    "${message}" \
      --region     "${AWS_REGION}" \
      --no-cli-pager 2>/dev/null &   # Non-blocking
    log "INFO" "SNS notification sent: ${subject}"
  fi
}

# setup awscli and resources
aws_setup(){
  echo "Automatic AWS setup incoming."
}

# =============================================================================
#  TASK CRUD — Core business logic
# =============================================================================

# ── ADD TASK ─────────────────────────────────────────────────────────────────
add_task() {
  clear
  print_dline
  echo -e "  ${BOLD_BLUE}  ADD NEW TASK${RESET}"
  print_dline
  blank

  # Collect and validate: name
  local name
  while true; do
    read -rp "  Name  : " name
    if validate_not_empty "${name}"; then break; fi
    error_msg "Project name cannot be empty."
  done

  # Collect and validate: Description
  local description
  while true; do
    read -rp "  Description  : " description
    if validate_not_empty "${description}"; then break; fi
    error_msg "Description cannot be empty."
  done

  # Category
  local category
  while true; do
    read -rp "  Category     : " category
    if validate_not_empty "${category}"; then break; fi
    error_msg "Category cannot be empty."
  done

  # Priority
  local priority
  while true; do
    read -rp "  Priority     [HIGH/MEDIUM/LOW]: " priority
    priority="${priority^^}"   # Uppercase
    if validate_priority "${priority}"; then break; fi
    error_msg "Priority must be HIGH, MEDIUM, or LOW."
  done

  # Due Date
  local due_date
  while true; do
    read -rp "  Due Date     [YYYY-MM-DD]: " due_date
    if validate_date "${due_date}"; then break; fi
    error_msg "Invalid date. Use format YYYY-MM-DD (e.g. 2025-12-31)."
  done

  # Build record
  local id; id=$(get_next_id)
  local now;  now=$(date '+%Y-%m-%d %H:%M')
  local record="${id},${name},${description},${category},${priority},${due_date},PENDING,${now},,,"

  # Append to CSV
  echo "${record}" >> "${TASKS_FILE}"

  blank
  success "Task #${id} created — '${description}'"
  log "CREATED" "Task added — ID:${id} | Desc:${description} | Priority:${priority} | Due:${due_date}"

  # Send SNS alert for HIGH priority tasks
  if [[ "${priority}" == "HIGH" ]]; then
    message=$(cat <<EOF
Hi Team,

High Piority Task alert.

Task ID:  #${id}
Project Name: ${name}
Description: ${description}
Due Date: ${due_date}
Category: ${category}

Regards,
CloudTask Team.
EOF
)

    sns_notify \
      "[CloudTask] HIGH Priority Task Created" \
      "$message"
    info "Alert sent for HIGH priority task."
  fi

  # Auto-backup after every add
  s3_backup

  _press_enter
}


# ── LIST ALL TASKS ────────────────────────────────────────────────────────────
list_tasks() {
  local filter_field="${1:-}"    # optional: category/priority/status
  local filter_value="${2:-}"    # optional: value to match

  clear
  print_dline
  echo -e "  ${BOLD_BLUE}  TASK LIST${RESET}${DIM}  $(date '+%Y-%m-%d %H:%M')${RESET}"
  print_dline

  # Check for data
  local total
  total=$(tail -n +2 "${TASKS_FILE}" | wc -l)

  if [[ "${total}" -eq 0 ]]; then
    blank
    warn "No tasks found. Use option 1 to add your first task."
    _press_enter
    return
  fi

  blank
  # Table header
  printf "  ${BOLD_CYAN}%-5s  %-20s  %-35s  %-12s  %-8s  %-12s  %-12s${RESET}\n" \
    "ID" "NAME" "DESCRIPTION" "CATEGORY" "PRIORITY" "DUE DATE" "STATUS"
  print_line

  local shown=0 page=1 line_count=0

  while IFS=',' read -r id name desc cat pri due status created updated completed; do
    # Skip header row
    [[ "${id}" == "ID" ]] && continue

    # Apply filter if set
    if [[ -n "${filter_field}" && -n "${filter_value}" ]]; then
      case "${filter_field}" in
        name) [[ "${name,,}" != "${filter_value,,}" ]] && continue ;;
        category) [[ "${cat,,}" != "${filter_value,,}" ]] && continue ;;
        priority) [[ "${pri^^}" != "${filter_value^^}" ]] && continue ;;
        status)   [[ "${status^^}" != "${filter_value^^}" ]] && continue ;;
      esac
    fi

    # Colour-code status
    local status_label
    if [[ "${status}" == "COMPLETED" ]]; then
      status_label="${GREEN}✔ Done${RESET}"
    elif [[ "${status}" == "PENDING" ]]; then
      # Warn if overdue
      if [[ -n "${due}" ]] && [[ "$(date -d "${due}" +%s 2>/dev/null)" -lt "$(date +%s)" ]]; then
        status_label="${RED}⚠ Overdue${RESET}"
      else
        status_label="${YELLOW}☐ Pending${RESET}"
      fi
    else
      status_label="${DIM}${status}${RESET}"
    fi

    # Colour-code priority
    local pri_label
    case "${pri}" in
      HIGH)   pri_label="${BOLD_RED}HIGH${RESET}"   ;;
      MEDIUM) pri_label="${YELLOW}MED${RESET}"      ;;
      LOW)    pri_label="${GREEN}LOW${RESET}"       ;;
      *)      pri_label="${pri}"                    ;;
    esac

    # Truncate long descriptions
    local short_desc="${desc:0:26}"
    [[ "${#desc}" -gt 26 ]] && short_desc="${short_desc}.."

    printf "  %-5s  %-20s  %-35s  %-12s  %-8s  %-12s  %-12s\n" \
    "${id}" \
    "${name:0:20}" \
    "${short_desc:0:35}" \
    "${cat:0:12}" \
    "${pri_label}" \
    "${due}" \
    "${status_label}"

    shown=$((shown + 1))
    line_count=$((line_count + 1))

    # Pagination
    if [[ "${line_count}" -ge "${PAGE_SIZE}" ]]; then
      print_line
      echo -e "  ${DIM}--- Page ${page} | Press Enter for more, q to stop ---${RESET}"
      read -r -n1 input
      [[ "${input,,}" == "q" ]] && break
      page=$((page + 1))
      line_count=0
      clear
      printf "  ${BOLD_CYAN}%-5s %-12s %-28s %-12s %-8s %-12s %-10s${RESET}\n" \
        "ID" "NAME" "DESCRIPTION" "CATEGORY" "PRIORITY" "DUE DATE" "STATUS"
      print_line
    fi

  done < "${TASKS_FILE}"

  print_line
  echo -e "  ${DIM}Showing ${shown} task(s)${RESET}"
  log "INFO" "List tasks viewed — ${shown} records displayed"
  _press_enter
}

# ── MARK TASK COMPLETE ────────────────────────────────────────────────────────
mark_complete() {
  clear
  print_dline
  echo -e "  ${BOLD_BLUE}  MARK TASK AS COMPLETE${RESET}"
  print_dline
  blank

  # Show a compact listing first
  list_tasks_compact

  local id
  read -rp "  Enter Task ID to mark complete: " id

  if ! validate_id_exists "${id}"; then
    error_msg "Task #${id} not found."
    _press_enter; return
  fi

  # Get current status
  local current_status
  current_status=$(grep "^${id}," "${TASKS_FILE}" | cut -d',' -f6)

  if [[ "${current_status}" == "COMPLETED" ]]; then
    warn "Task #${id} is already marked as complete."
    _press_enter; return
  fi

  # Update status and set CompletedAt timestamp
  local now; now=$(date '+%Y-%m-%d %H:%M')
  # Using awk to safely update specific columns (7=Status, 9=UpdatedAt, 10=CompletedAt)
  awk -F',' -v id="${id}" -v now="${now}" 'BEGIN{OFS=","} {
    if ($1 == id) { $7="COMPLETED"; $9=now; $10=now }
    print
  }' "${TASKS_FILE}" > "${TASKS_FILE}.tmp" && mv "${TASKS_FILE}.tmp" "${TASKS_FILE}"

  blank
  success "Task #${id} marked as COMPLETE."
  log "INFO" "Task completed — ID:${id}"
  
  s3_backup

  _press_enter
}


# ── UPDATE TASK ───────────────────────────────────────────────────────────────
update_task() {
  clear
  print_dline
  echo -e "  ${BOLD_BLUE}  UPDATE TASK${RESET}"
  print_dline
  blank

  list_tasks_compact

  local id
  read -rp "  Enter Task ID to update: " id

  if ! validate_id_exists "${id}"; then
    error_msg "Task #${id} not found."
    _press_enter; return
  fi

  # Read current values
  local current_line
  current_line=$(grep "^${id}," "${TASKS_FILE}")

  local cur_name cur_desc cur_cat cur_pri cur_due
  cur_name=$(echo "${current_line}" | cut -d',' -f2)
  cur_desc=$(echo "${current_line}" | cut -d',' -f3)
  cur_cat=$(echo  "${current_line}" | cut -d',' -f4)
  cur_pri=$(echo  "${current_line}" | cut -d',' -f5)
  cur_due=$(echo  "${current_line}" | cut -d',' -f6)

  echo -e "\n  ${YELLOW}Press Enter to keep current value:${RESET}\n"

  # Prompt with existing values as defaults
  local new_name new_desc new_cat new_pri new_due

  read -rp "  Name  [${cur_desc}]: " new_name
  new_name="${new_name:-${cur_name}}"

  read -rp "  Description  [${cur_desc}]: " new_desc
  new_desc="${new_desc:-${cur_desc}}"

  read -rp "  Category     [${cur_cat}]: " new_cat
  new_cat="${new_cat:-${cur_cat}}"

  while true; do
    read -rp "  Priority     [${cur_pri}] HIGH/MEDIUM/LOW: " new_pri
    new_pri="${new_pri:-${cur_pri}}"
    new_pri="${new_pri^^}"
    if validate_priority "${new_pri}"; then break; fi
    error_msg "Invalid priority."
  done

  while true; do
    read -rp "  Due Date     [${cur_due}] YYYY-MM-DD: " new_due
    new_due="${new_due:-${cur_due}}"
    if validate_date "${new_due}"; then break; fi
    error_msg "Invalid date format."
  done

  local now; now=$(date '+%Y-%m-%d %H:%M')

  # awk updates columns safely without breaking other fields
  awk -F',' -v id="${id}" -v n="${new_name}"  -v d="${new_desc}" -v c="${new_cat}" \
      -v p="${new_pri}" -v due="${new_due}" -v now="${now}" \
      'BEGIN{OFS=","} {
        if ($1 == id) { $2=n; $3=d; $4=c; $5=p;  $6=due; $9=now }
        print
      }' "${TASKS_FILE}" > "${TASKS_FILE}.tmp" && mv "${TASKS_FILE}.tmp" "${TASKS_FILE}"

  blank
  success "Task #${id} updated."
  log "UPDATE" "Task updated — ID:${id} | Name:${new_name} | Desc:${new_desc} | Pri:${new_pri} | Due:${new_due}"
  
  s3_backup

  _press_enter
}


# ── DELETE TASK ───────────────────────────────────────────────────────────────
delete_task() {
  clear
  print_dline
  echo -e "  ${BOLD_BLUE}  DELETE TASK${RESET}"
  print_dline
  blank

  list_tasks_compact

  local id
  read -rp "  Enter Task ID to delete: " id

  if ! validate_id_exists "${id}"; then
    error_msg "Task #${id} not found."
    _press_enter; return
  fi

  # Show what will be deleted
  local line
  line=$(grep "^${id}," "${TASKS_FILE}")
  local desc; desc=$(echo "${line}" | cut -d',' -f2)

  blank
  warn "You are about to permanently delete:"
  echo -e "  ${BOLD_RED}  ID: ${id}  |  ${desc}${RESET}"
  blank

  read -rp "  Type 'DELETE' to confirm: " confirm

  if [[ "${confirm}" != "DELETE" ]]; then
    warn "Deletion cancelled."
    _press_enter; return
  fi

  # Create a local backup before deleting
  cp "${TASKS_FILE}" "${BACKUP_DIR}/tasks_pre_delete_$(date +%s).csv"

  # Remove the matching line
  grep -v "^${id}," "${TASKS_FILE}" > "${TASKS_FILE}.tmp" \
    && mv "${TASKS_FILE}.tmp" "${TASKS_FILE}"

  blank
  success "Task #${id} ('${desc}') deleted."
  log "DELETE" "Task deleted — ID:${id} | Desc:${desc}"
  
  s3_backup

  _press_enter
}


# ── SEARCH ────────────────────────────────────────────────────────────────────
search_tasks() {
  clear
  print_dline
  echo -e "  ${BOLD_BLUE}  SEARCH TASKS${RESET}"
  print_dline
  blank

  read -rp "  Enter search term: " term

  if [[ -z "${term}" ]]; then
    error_msg "Search term cannot be empty."
    _press_enter; return
  fi

  blank
  info "Results for: '${term}'"
  print_line
  printf "  ${BOLD_CYAN}%-5s %-30s %-12s %-8s %-12s %-10s${RESET}\n" \
    "ID" "DESCRIPTION" "CATEGORY" "PRIORITY" "DUE DATE" "STATUS"
  print_line

  local found=0
  while IFS=',' read -r id desc cat pri due status rest; do
    [[ "${id}" == "ID" ]] && continue
    # Case-insensitive search across description and category
    if echo "${desc} ${cat}" | grep -qi "${term}"; then
      printf "  %-5s %-30s %-12s %-8s %-12s %-10s\n" \
        "${id}" "${desc:0:28}" "${cat:0:12}" "${pri}" "${due}" "${status}"
      found=$((found + 1))
    fi
  done < "${TASKS_FILE}"

  print_line
  echo -e "  ${DIM}${found} result(s) found${RESET}"
  log "INFO" "Search performed — term:'${term}' | results:${found}"
  _press_enter
}

# ── STATISTICS ────────────────────────────────────────────────────────────────
show_stats() {
  clear
  print_dline
  echo -e "  ${BOLD_BLUE}  STATISTICS & REPORTS${RESET}"
  print_dline
  blank

  local total pending completed high medium low overdue
  total=$(tail -n +2 "${TASKS_FILE}" | wc -l)
  pending=$(grep -c ",PENDING," "${TASKS_FILE}" 2>/dev/null || echo 0)
  completed=$(grep -c ",COMPLETED," "${TASKS_FILE}" 2>/dev/null || echo 0)
  high=$(grep -c ",HIGH," "${TASKS_FILE}" 2>/dev/null || echo 0)
  medium=$(grep -c ",MEDIUM," "${TASKS_FILE}" 2>/dev/null || echo 0)
  low=$(grep -c ",LOW," "${TASKS_FILE}" 2>/dev/null || echo 0)

  # Count overdue: PENDING tasks with due date before today
  overdue=0
  while IFS=',' read -r id desc cat pri due status rest; do
    [[ "${id}" == "ID" ]] && continue
    [[ "${status}" != "PENDING" ]] && continue
    if [[ -n "${due}" ]] && [[ "$(date -d "${due}" +%s 2>/dev/null)" -lt "$(date +%s)" ]]; then
      overdue=$((overdue + 1))
    fi
  done < "${TASKS_FILE}"

  # Completion rate
  local rate=0
  [[ "${total}" -gt 0 ]] && rate=$(( completed * 100 / total ))

  echo -e "  ${BOLD_CYAN}  OVERVIEW${RESET}"
  printf "  %-25s %s\n" "Total Tasks:"     "${total}"
  printf "  %-25s ${GREEN}%s${RESET}\n"    "Completed:"       "${completed}"
  printf "  %-25s ${YELLOW}%s${RESET}\n"   "Pending:"         "${pending}"
  printf "  %-25s ${RED}%s${RESET}\n"      "Overdue:"         "${overdue}"
  printf "  %-25s %s%%\n"                  "Completion Rate:" "${rate}"
  blank

  echo -e "  ${BOLD_CYAN}  BY PRIORITY${RESET}"
  printf "  %-25s ${BOLD_RED}%s${RESET}\n"    "High:"   "${high}"
  printf "  %-25s ${YELLOW}%s${RESET}\n"      "Medium:" "${medium}"
  printf "  %-25s ${GREEN}%s${RESET}\n"       "Low:"    "${low}"
  blank

  # Visual completion bar
  local bar_filled=$(( rate / 5 ))
  local bar_empty=$(( 20 - bar_filled ))
  local bar=""
  for ((i=0; i<bar_filled; i++)); do bar="${bar}█"; done
  for ((i=0; i<bar_empty;  i++)); do bar="${bar}░"; done
  echo -e "  ${BOLD_CYAN}  PROGRESS${RESET}"
  echo -e "  ${GREEN}${bar}${RESET}  ${rate}%"
  blank

  log "INFO" "Statistics viewed — total:${total} | completed:${completed} | pending:${pending}"
  _press_enter
}


# ── FILTER MENU ───────────────────────────────────────────────────────────────
filter_menu() {
  clear
  print_dline
  echo -e "  ${BOLD_BLUE}  FILTER TASKS${RESET}"
  print_dline
  blank
  echo "  1. Filter by Category"
  echo "  2. Filter by Priority"
  echo "  3. Filter by Status"
  echo "  4. Show Overdue Tasks"
  blank
  read -rp "  Choose filter [1-4]: " choice

  case "${choice}" in
    1)
      read -rp "  Category name: " val
      list_tasks "category" "${val}"
      ;;
    2)
      read -rp "  Priority [HIGH/MEDIUM/LOW]: " val
      list_tasks "priority" "${val}"
      ;;
    3)
      read -rp "  Status [PENDING/COMPLETED]: " val
      list_tasks "status" "${val}"
      ;;
    4)
      # Show only overdue pending tasks
      clear
      print_dline
      echo -e "  ${BOLD_RED}  OVERDUE TASKS${RESET}"
      print_dline
      blank
      printf "  ${BOLD_CYAN}%-5s %-28s %-12s %-8s %-12s${RESET}\n" \
        "ID" "DESCRIPTION" "CATEGORY" "PRIORITY" "DUE DATE"
      print_line
      local found=0
      while IFS=',' read -r id desc cat pri due status rest; do
        [[ "${id}" == "ID" ]] && continue
        [[ "${status}" != "PENDING" ]] && continue
        if [[ -n "${due}" ]] && [[ "$(date -d "${due}" +%s 2>/dev/null)" -lt "$(date +%s)" ]]; then
          printf "  ${RED}%-5s %-28s %-12s %-8s %-12s${RESET}\n" \
            "${id}" "${desc:0:26}" "${cat:0:12}" "${pri}" "${due}"
          found=$((found + 1))
        fi
      done < "${TASKS_FILE}"
      print_line
      echo -e "  ${DIM}${found} overdue task(s)${RESET}"
      _press_enter
      ;;
    *)
      error_msg "Invalid option."
      _press_enter
      ;;
  esac
}


# ── EXPORT ────────────────────────────────────────────────────────────────────
export_tasks() {
  clear
  print_dline
  echo -e "  ${BOLD_BLUE}  EXPORT TASKS${RESET}"
  print_dline
  blank

  echo -e "  ${CYAN}Export format:${RESET}"
  echo "  1. CSV  (tasks_export_DATE.csv)"
  echo "  2. TXT  (plain text table)"
  blank
  read -rp "  Choose format [1/2]: " fmt

  local ts; ts=$(date '+%Y%m%d_%H%M%S')

  case "${fmt}" in
    1)
      local csv_out="${DATA_DIR}/tasks_export_${ts}.csv"
      cp "${TASKS_FILE}" "${csv_out}"
      success "Exported to: ${csv_out}"
      log "INFO" "Tasks exported to CSV: ${csv_out}"

      # Optionally push to S3
      if aws_available; then
        read -rp "  Upload export to S3? [y/N]: " upload
        if [[ "${upload,,}" == "y" ]]; then
          aws s3 cp "${csv_out}" \
            "s3://${S3_BUCKET}/exports/tasks_export_${ts}.csv" \
            --region "${AWS_REGION}" \
            --no-cli-pager && \
            success "Uploaded to s3://${S3_BUCKET}/exports/"
        fi
      fi
      ;;
    2)
      local txt_out="${DATA_DIR}/tasks_export_${ts}.txt"
      {
        printf "%-5s %-30s %-12s %-8s %-12s %-10s\n" \
          "ID" "DESCRIPTION" "CATEGORY" "PRIORITY" "DUE DATE" "STATUS"
        printf '%.0s─' {1..80}; echo
        while IFS=',' read -r id desc cat pri due status rest; do
          [[ "${id}" == "ID" ]] && continue
          printf "%-5s %-30s %-12s %-8s %-12s %-10s\n" \
            "${id}" "${desc:0:28}" "${cat:0:12}" "${pri}" "${due}" "${status}"
        done < "${TASKS_FILE}"
      } > "${txt_out}"
      success "Exported to: ${txt_out}"
      log "INFO" "Tasks exported to TXT: ${txt_out}"
      ;;
    *)
      error_msg "Invalid selection."
      ;;
  esac
  _press_enter
}


# ── CLOUD MENU ────────────────────────────────────────────────────────────────
cloud_menu() {
  clear
  print_dline
  echo -e "  ${BOLD_BLUE}  AWS CLOUD OPERATIONS${RESET}"
  print_dline
  blank
  echo "  1. Back up tasks to S3 now"
  echo "  2. Restore tasks from S3"
  echo "  3. Set up AWS resources: S3, SNS, CloudWatch (required)"
  echo "  4. View AWS configuration"
  blank
  read -rp "  Choose [1-3]: " choice

  case "${choice}" in
    1) s3_backup;  _press_enter ;;
    2)
      warn "This will OVERWRITE your local tasks with the S3 backup."
      read -rp "  Proceed? [yes/NO]: " confirm
      [[ "${confirm}" == "yes" ]] && s3_restore
      _press_enter
      ;;
    3) aws_setup; _press_enter ;;
    4)
      blank
      echo -e "  ${CYAN}AWS Region   :${RESET} ${AWS_REGION:-not set}"
      echo -e "  ${CYAN}S3 Bucket    :${RESET} ${S3_BUCKET:-not set}"
      echo -e "  ${CYAN}SNS Topic    :${RESET} ${SNS_TOPIC_ARN:-not set}"
      echo -e "  ${CYAN}CW Log Group :${RESET} ${CW_LOG_GROUP:-not set}"
      echo -e "  ${CYAN}AWS CLI      :${RESET} $(command -v aws 2>/dev/null || echo 'not installed')"
      _press_enter
      ;;
    *) error_msg "Invalid option."; _press_enter ;;
  esac
}


# =============================================================================
#  MAIN MENU
# =============================================================================

main_menu() {
  clear
  print_dline
  echo -e "${BOLD_CYAN}"
  echo "                      ╔══════════════════════════════════════════╗"
  echo "                      ║            CloudTask ${APP_VERSION}          ║"
  echo "                      ║    AWS-Integrated Terminal Task Manager  ║"
  echo "                      ╚══════════════════════════════════════════╝"
  echo -e "${RESET}"
  print_dline

  # Show pending and overdue count at-a-glance
  local pending; pending=$(grep -c ",PENDING," "${TASKS_FILE}" 2>/dev/null || echo 0)
  local completed; completed=$(grep -c ",COMPLETED," "${TASKS_FILE}" 2>/dev/null || echo 0)

  echo -e "  ${DIM}Pending: ${YELLOW}${pending}${RESET}  |  ${DIM}Completed: ${GREEN}${completed}${RESET}"

  blank

  echo -e "  ${BOLD_CYAN}TASK MANAGEMENT${RESET}"
  echo -e "  ${GREEN}1.${RESET}  Add New Task"
  echo -e "  ${GREEN}2.${RESET}  List All Tasks"
  echo -e "  ${GREEN}3.${RESET}  Mark Task as Complete"
  echo -e "  ${GREEN}4.${RESET}  Update Task"
  echo -e "  ${GREEN}5.${RESET}  Delete Task"
  blank
  echo -e "  ${BOLD_CYAN}FIND & ANALYSE${RESET}"
  echo -e "  ${GREEN}6.${RESET}  Search Tasks"
  echo -e "  ${GREEN}7.${RESET}  Filter Tasks"
  echo -e "  ${GREEN}8.${RESET}  Statistics & Reports"
  blank
  echo -e "  ${BOLD_CYAN}DATA & CLOUD${RESET}"
  echo -e "  ${GREEN}9.${RESET}  Export Tasks"
  echo -e "  ${GREEN}10.${RESET} AWS Cloud Operations  ${DIM}(S3 / SNS / CloudWatch)${RESET}"
  blank
  echo -e "  ${RED}0.${RESET}  Exit"
  blank
  print_dline
  read -rp "  Enter option [0-10]: " choice
}

# =============================================================================
#  ENTRY POINT
# =============================================================================

main() {
  # Handle CLI flags
  case "${1:-}" in
    --help|-h) print_help; exit 0 ;;
    add)       bootstrap; acquire_lock; add_task; exit 0 ;;
    list)      bootstrap; acquire_lock; list_tasks; exit 0 ;;
  esac

  # Interactive mode
  bootstrap
  acquire_lock
  log "INFO" "Application started — user:$(whoami) | host:$(hostname)"

  while true; do
    main_menu
    case "${choice}" in
      1)  add_task      ;;
      2)  list_tasks    ;;
      3)  mark_complete ;;
      4)  update_task   ;;
      5)  delete_task   ;;
      6)  search_tasks  ;;
      7)  filter_menu   ;;
      8)  show_stats    ;;
      9)  export_tasks  ;;
      10) cloud_menu    ;;
      0)
        blank
        echo -e "  ${CYAN}Goodbye! Session logged to ${LOG_FILE}${RESET}"
        blank
        log "INFO" "Application exited — user:$(whoami)"
        exit 0
        ;;
      *)
        error_msg "Invalid option '${choice}'. Please enter a number between 0 and 10."
        sleep 1
        ;;
    esac
  done
}

main "$@"


