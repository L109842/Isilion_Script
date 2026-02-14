#!/usr/bin/env bash
# Isilon/PowerScale Interactive WORM Delete Script (v1 - FINAL)
#
# v1 includes:
# 1) Batch validation for folder/file exclusion lists (enter all, then summary table)
# 2) Robust file matching under BASE + subdirectories (whitespace -> wildcard)
# 3) If a DIRECTORY is entered in file exclusion list: minimal y/n confirm to exclude subtree
# 4) Owner/UID exclusion excludes ONLY files owned by UID (recursive under BASE)
# 5) Folder exclusions resolve directories only (so "2019" doesn't match *2019*.pdf)
# 6) Safer handling: MULTI matches are NOT auto-applied (warn + force R/C/A decision)
# 7) Candidate Review Phase:
#    - Writes exact candidate files to /tmp/<REQ>_candidate_files.txt
#    - Shows preview
#    - Requires operator to type CONFIRM, then YES to actually delete
#
# WORM modes:
#   FAST   (default): attempt delete directly, log failures
#   STRICT           : precheck `isi worm files view`, delete COMMITTED only (slower)

set -euo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }
[[ -n "${BASH_VERSION:-}" ]] || die "Run with bash"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WORM_CHECK_MODE="${WORM_CHECK_MODE:-FAST}"   # FAST|STRICT

# ---------------- GLOBAL ANSWERS ----------------
YN_ANSWER=""          # "y"|"n"
OWNER_ANSWER_TYPE=""  # "y"|"n"|"OWNER"
OWNER_ANSWER_VAL=""   # owner string when OWNER_ANSWER_TYPE="OWNER"

# ---------------- STRICT y/n FUNCTION ----------------
ask_yn_strict() {
  local prompt="$1"
  local ans=""
  while true; do
    read -r -p "$prompt (y/n): " ans
    ans="${ans//[[:space:]]/}"
    case "$ans" in
      y|Y) YN_ANSWER="y"; return 0 ;;
      n|N) YN_ANSWER="n"; return 0 ;;
      *) echo "WARNING: Invalid input [$ans]. Please enter y or n only." ;;
    esac
  done
}

# Owner prompt: allows y/n OR direct owner/UID string
ask_owner_or_yn() {
  local prompt="$1"
  local ans=""
  while true; do
    read -r -p "$prompt (y/n or enter user/UID directly): " ans
    ans="${ans#"${ans%%[![:space:]]*}"}"
    ans="${ans%"${ans##*[![:space:]]}"}"
    [[ -z "${ans:-}" ]] && { echo "WARNING: Enter y, n, or a user/UID."; continue; }

    case "${ans,,}" in
      y) OWNER_ANSWER_TYPE="y"; OWNER_ANSWER_VAL=""; return 0 ;;
      n) OWNER_ANSWER_TYPE="n"; OWNER_ANSWER_VAL=""; return 0 ;;
      *) OWNER_ANSWER_TYPE="OWNER"; OWNER_ANSWER_VAL="$ans"; return 0 ;;
    esac
  done
}

confirm_yes_or_menu(){
  echo ""
  read -r -p "Type EXACTLY 'YES' to proceed. Anything else returns to main menu: " c
  [[ "${c:-}" == "YES" ]] && return 0
  echo "Not confirmed. Returning to main menu..."
  echo ""
  return 1
}

msg_no_input(){ echo "ERROR: No input provided. Returning to main menu..."; echo ""; }
msg_abort(){ echo "ABORTED by operator. Returning to main menu..."; echo ""; }

append_unique() {
  local -n arr="$1"
  local val="$2"
  local x
  for x in "${arr[@]}"; do [[ "$x" == "$val" ]] && return 0; done
  arr+=("$val")
}

print_list() {
  local -n arr="$1"
  if [[ ${#arr[@]} -eq 0 ]]; then
    echo "  (none)"
  else
    local i=1 v
    for v in "${arr[@]}"; do
      echo "  $i) $v"
      ((i++))
    done
  fi
}

is_number(){ [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# ---------------- NORMALIZATION HELPERS ----------------
normalize_token() {
  # Convert one-or-more whitespace into wildcard '*'
  # Example: "A  B   C.docx" => "A*B*C.docx"
  local s="$1"
  echo "$s" | sed 's/[[:space:]]\+/*/g'
}

clean_relpath() {
  # Remove leading ./ and collapse /./ and trailing /
  local p="$1"
  p="${p#./}"
  p="${p%/}"
  while [[ "$p" == *"/./"* ]]; do p="${p//\/.\//\/}"; done
  echo "$p"
}

clean_path() {
  # Clean absolute paths: remove /./ and trailing /
  local p="$1"
  p="${p%/}"
  while [[ "$p" == *"/./"* ]]; do p="${p//\/.\//\/}"; done
  echo "$p"
}

# ---------------- OWNER VALIDATION ----------------
OWNER_OK="0"
OWNER_UID_RESOLVED=""
OWNER_NAME_RESOLVED=""

validate_owner_or_uid() {
  local inp="$1"
  OWNER_OK="0"
  OWNER_UID_RESOLVED=""
  OWNER_NAME_RESOLVED=""

  [[ -z "${inp:-}" ]] && return 1

  if is_number "$inp"; then
    if getent passwd "$inp" >/dev/null 2>&1; then
      OWNER_UID_RESOLVED="$inp"
      OWNER_NAME_RESOLVED="$(getent passwd "$inp" | awk -F: '{print $1}' | head -n 1)"
      OWNER_OK="1"
      return 0
    else
      return 1
    fi
  else
    local uid=""
    uid="$(id -u -- "$inp" 2>/dev/null || true)"
    if [[ -n "$uid" && "$uid" =~ ^[0-9]+$ ]]; then
      OWNER_UID_RESOLVED="$uid"
      OWNER_NAME_RESOLVED="$(id -un -- "$inp" 2>/dev/null || echo "$inp")"
      OWNER_OK="1"
      return 0
    fi

    if getent passwd "$inp" >/dev/null 2>&1; then
      OWNER_NAME_RESOLVED="$(getent passwd "$inp" | awk -F: '{print $1}' | head -n 1)"
      OWNER_UID_RESOLVED="$(getent passwd "$inp" | awk -F: '{print $3}' | head -n 1)"
      [[ -n "$OWNER_UID_RESOLVED" ]] && OWNER_OK="1" && return 0
    fi
    return 1
  fi
}

count_owner_matches_by_uid() {
  local base="$1" uid="$2" c=0
  [[ -z "${uid:-}" ]] && { echo 0; return 0; }
  while IFS= read -r -d '' _; do ((c++)) || true; done < <(find "$base" -xdev -type f -uid "$uid" -print0 2>/dev/null || true)
  echo "$c"
}

# ---------------- WORM HELPERS ----------------
worm_state_of() {
  local file="$1"
  local out state
  out="$(isi worm files view "$file" 2>&1 || true)"
  state="$(printf '%s\n' "$out" | awk -F': *' '/WORM State:/ {print $2; exit}')"
  [[ -n "${state:-}" ]] || state="UNKNOWN"
  echo "$state"
}

# ---------------- RESOLVERS ----------------
# Directory-only resolution for folder exclusion section
resolve_dirs_only() {
  local base="$1" entry="$2"
  local -n out_dirs="$3"
  out_dirs=()

  entry="$(clean_relpath "$entry")"

  if [[ "$entry" == /* ]]; then
    [[ -d "$entry" ]] && out_dirs+=("$(clean_path "$entry")")
    return 0
  fi

  if [[ "$entry" == *"/"* ]]; then
    local candidate="$base/$entry"
    [[ -d "$candidate" ]] && out_dirs+=("$(clean_path "$candidate")")
    while IFS= read -r -d '' d; do out_dirs+=("$(clean_path "$d")"); done < <(
      find "$base" -xdev -type d -path "*$entry*" -print0 2>/dev/null || true
    )
    return 0
  fi

  while IFS= read -r -d '' d; do out_dirs+=("$(clean_path "$d")"); done < <(
    find "$base" -xdev -type d -iname "*$entry*" -print0 2>/dev/null || true
  )
}

# File-only resolution for file exclusion section (robust spacing)
resolve_files_only() {
  local base="$1" entry="$2"
  local -n out_files="$3"
  out_files=()

  entry="${entry#"${entry%%[![:space:]]*}"}"
  entry="${entry%"${entry##*[![:space:]]}"}"
  entry="$(clean_relpath "$entry")"

  if [[ "$entry" == /* ]]; then
    [[ -f "$entry" ]] && out_files+=("$(clean_path "$entry")")
    return 0
  fi

  if [[ "$entry" == *"/"* ]]; then
    local candidate="$base/$entry"
    [[ -f "$candidate" ]] && out_files+=("$(clean_path "$candidate")")
    while IFS= read -r -d '' f; do out_files+=("$(clean_path "$f")"); done < <(
      find "$base" -xdev -type f -path "*$entry*" -print0 2>/dev/null || true
    )
    return 0
  fi

  local token
  token="$(normalize_token "$entry")"
  while IFS= read -r -d '' f; do out_files+=("$(clean_path "$f")"); done < <(
    find "$base" -xdev -type f -iname "*$token*" -print0 2>/dev/null || true
  )
}

# Detect whether a "file exclusion" entry is actually a directory reference under BASE
resolve_directory_reference_from_file_entry() {
  local base="$1" entry="$2"

  entry="${entry#"${entry%%[![:space:]]*}"}"
  entry="${entry%"${entry##*[![:space:]]}"}"
  entry="$(clean_relpath "$entry")"

  if [[ "$entry" == /* ]]; then
    [[ -d "$entry" ]] && { echo "$(clean_path "$entry")"; return 0; }
    echo ""
    return 0
  fi

  local candidate="$base/$entry"
  [[ -d "$candidate" ]] && { echo "$(clean_path "$candidate")"; return 0; }

  echo ""
}

confirm_directory_exclusion_minimal() {
  local dir="$1"
  local ans=""
  echo "NOTICE: [$dir] is a DIRECTORY, not a file."
  while true; do
    read -r -p "Do you want to EXCLUDE this directory (entire subtree)? (y/n): " ans
    case "${ans,,}" in
      y) append_unique EXCLUDE_DIRS "$dir"; echo "Directory excluded: $dir"; return 0 ;;
      n) echo "Directory not excluded."; return 0 ;;
      *) echo "WARNING: Invalid input [$ans]. Please enter y or n only." ;;
    esac
  done
}

# ---------- logging setup ----------
read -r -p "Enter Request number (example: RITM5981027 or INC123456): " REQ
[[ -n "${REQ:-}" ]] || die "Request number cannot be empty."
SAFE_REQ="$(echo "$REQ" | tr -cd '[:alnum:]_-')"

if [[ "$SAFE_REQ" =~ ^(RITM|INC)[0-9]+$ ]]; then
  LOGFILE="${SCRIPT_DIR}/${SAFE_REQ}.log"
else
  LOGFILE="${SCRIPT_DIR}/RITM_${SAFE_REQ}.log"
fi

# Log to screen + logfile
exec > >(tee -a "$LOGFILE") 2>&1

echo "==============================================================="
echo "Isilon WORM Delete (v1 - candidate review + batch validation)"
echo "Request   : $REQ"
echo "Log file  : $LOGFILE"
echo "Operator  : $(id -un) (uid=$(id -u))"
echo "Host      : $(hostname)"
echo "Started   : $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "WORM mode : $WORM_CHECK_MODE"
echo "==============================================================="
echo ""

read -r -p "Enter comments/notes for this request (optional, press Enter to skip): " USER_NOTE
[[ -n "${USER_NOTE:-}" ]] && echo "NOTE: $USER_NOTE"

run_base_delete() {
  local MODE="$1" MODE_NAME="$2"

  read -r -p "Enter the BASE folder path: " BASE
  [[ -n "${BASE:-}" ]] || { msg_no_input; return 1; }

  # Convenience: if user forgets leading '/', try adding it
  if [[ "$BASE" != /* && -d "/$BASE" ]]; then
    BASE="/$BASE"
  fi

  [[ -d "$BASE" ]] || { echo "ERROR: Base path does not exist or is not a directory: $BASE"; echo ""; return 1; }
  BASE="$(cd "$BASE" && pwd -P)"

  case "$BASE" in
    "/"|"/ifs"|"/ifs/"|"/ifs/data"|"/ifs/data/")
      echo "ERROR: Refusing to operate on high-level path: $BASE. Provide a deeper folder."
      echo ""
      return 1
      ;;
  esac

  echo ""
  echo "BASE selected: $BASE"
  echo ""

  while true; do
    EXCLUDE_OWNER_INPUT=""
    EXCLUDE_OWNER_UID=""
    EXCLUDE_OWNER_NAME=""
    declare -a EXCLUDE_DIRS=()
    declare -a EXCLUDE_FILES=()
    declare -a WARNINGS=()

    # --- owner prompt ---
    ask_owner_or_yn "Exclude files owned by a user/UID?"
    if [[ "$OWNER_ANSWER_TYPE" == "OWNER" ]]; then
      EXCLUDE_OWNER_INPUT="$OWNER_ANSWER_VAL"
    elif [[ "$OWNER_ANSWER_TYPE" == "y" ]]; then
      read -r -p "Enter username (e.g. AP\\c270183) OR numeric UID (e.g. 14473): " EXCLUDE_OWNER_INPUT
      [[ -n "${EXCLUDE_OWNER_INPUT:-}" ]] || { msg_no_input; return 1; }
    fi

    if [[ -n "${EXCLUDE_OWNER_INPUT:-}" ]]; then
      if validate_owner_or_uid "$EXCLUDE_OWNER_INPUT"; then
        EXCLUDE_OWNER_UID="$OWNER_UID_RESOLVED"
        EXCLUDE_OWNER_NAME="$OWNER_NAME_RESOLVED"
        echo "Owner verification: YES -> identified [$EXCLUDE_OWNER_INPUT] as user [$EXCLUDE_OWNER_NAME] (uid=$EXCLUDE_OWNER_UID)"
        owner_match="$(count_owner_matches_by_uid "$BASE" "$EXCLUDE_OWNER_UID")"
        echo "Owner/UID check: found $owner_match file(s) under BASE owned by uid=$EXCLUDE_OWNER_UID"
        echo "Action: files owned by uid=$EXCLUDE_OWNER_UID will be EXCLUDED from deletion candidates (BASE + all subdirectories)."
        [[ "$owner_match" -eq 0 ]] && WARNINGS+=("Owner [$EXCLUDE_OWNER_INPUT] exists (uid=$EXCLUDE_OWNER_UID) but matched 0 files under BASE.")
        echo ""
      else
        echo "Owner verification: NO -> [$EXCLUDE_OWNER_INPUT] does not resolve to a valid user/UID on this system."
        WARNINGS+=("Owner/UID [$EXCLUDE_OWNER_INPUT] is invalid / not found (no exclusion will be applied unless corrected).")
        echo ""
      fi
    fi

    # ---------- FOLDER EXCLUSIONS (BATCH) ----------
    ask_yn_strict "Do you want to EXCLUDE folder(s) (entire subtree)?"
    if [[ "$YN_ANSWER" == "y" ]]; then
      echo "Enter folder exclusion entries (FULL path, relative-to-BASE, or folder name)."
      echo "One per line. Blank line to finish:"
      declare -a FOLDER_INPUTS=()
      while true; do
        read -r dentry
        [[ -z "${dentry:-}" ]] && break
        FOLDER_INPUTS+=("$dentry")
      done

      echo ""
      printf "%-45s %-12s %s\n" "Folder" "Found" "Resolved Path"
      printf "%-45s %-12s %s\n" "---------------------------------------------" "----------" "------------------------------"

      for dentry in "${FOLDER_INPUTS[@]}"; do
        declare -a dm=()
        resolve_dirs_only "$BASE" "$dentry" dm

        if [[ ${#dm[@]} -eq 0 ]]; then
          printf "%-45s %-12s %s\n" "$dentry" "NO" "-"
          WARNINGS+=("Folder exclude entry [$dentry] matched 0 directories under BASE.")
        elif [[ ${#dm[@]} -eq 1 ]]; then
          printf "%-45s %-12s %s\n" "$dentry" "YES" "${dm[0]}"
          append_unique EXCLUDE_DIRS "${dm[0]}"
        else
          printf "%-45s %-12s %s\n" "$dentry" "MULTI(${#dm[@]})" "${dm[0]}"
          WARNINGS+=("Folder exclude entry [$dentry] matched multiple directories (${#dm[@]}). Please provide a more specific path.")
        fi
      done
      echo ""
    fi

    # ---------- FILE EXCLUSIONS (BATCH) ----------
    ask_yn_strict "Do you want to EXCLUDE file(s)? (FULL path or filename/partial under BASE)"
    if [[ "$YN_ANSWER" == "y" ]]; then
      echo "Enter file exclusion entries (FULL path, relative-to-BASE, or filename/partial token)."
      echo "One per line. Blank line to finish:"
      declare -a FILE_INPUTS=()
      while true; do
        read -r fentry
        [[ -z "${fentry:-}" ]] && break
        FILE_INPUTS+=("$fentry")
      done

      echo ""
      printf "%-55s %-12s %s\n" "File Entry" "Found" "Resolved (first match)"
      printf "%-55s %-12s %s\n" "-------------------------------------------------------" "----------" "------------------------------"

      for fentry in "${FILE_INPUTS[@]}"; do
        dref="$(resolve_directory_reference_from_file_entry "$BASE" "$fentry" || true)"
        if [[ -n "${dref:-}" ]]; then
          printf "%-55s %-12s %s\n" "$fentry" "DIR" "$dref"
          confirm_directory_exclusion_minimal "$dref"
          continue
        fi

        declare -a fm=()
        resolve_files_only "$BASE" "$fentry" fm

        if [[ ${#fm[@]} -eq 0 ]]; then
          printf "%-55s %-12s %s\n" "$fentry" "NO" "-"
          WARNINGS+=("File exclude entry [$fentry] matched 0 files under BASE.")
        elif [[ ${#fm[@]} -eq 1 ]]; then
          printf "%-55s %-12s %s\n" "$fentry" "YES" "${fm[0]}"
          append_unique EXCLUDE_FILES "${fm[0]}"
        else
          printf "%-55s %-12s %s\n" "$fentry" "MULTI(${#fm[@]})" "${fm[0]}"
          WARNINGS+=("File exclude entry [$fentry] matched multiple files (${#fm[@]}). Please provide a full path or a more unique token.")
        fi
      done
      echo ""
    fi

    echo ""
    echo "================ EXCLUSIONS (RESOLVED) ================"
    if [[ -n "${EXCLUDE_OWNER_INPUT:-}" ]]; then
      if [[ -n "${EXCLUDE_OWNER_UID:-}" ]]; then
        echo "Exclude owner resolved: $EXCLUDE_OWNER_NAME (uid=$EXCLUDE_OWNER_UID) -> EXCLUDING ONLY files by this UID"
      else
        echo "Exclude owner resolved: (INVALID / NOT FOUND) -> NO owner exclusion applied"
      fi
    else
      echo "Exclude owner/UID: (none)"
    fi
    echo ""
    echo "Exclude folders (subtree):"
    print_list EXCLUDE_DIRS
    echo ""
    echo "Exclude files (exact paths):"
    print_list EXCLUDE_FILES
    echo "======================================================="
    echo ""

    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
      echo "WARNINGS detected during exclude resolution:"
      for w in "${WARNINGS[@]}"; do echo "  - $w"; done
      echo ""
      echo "Choose next step:"
      echo "  R) Re-enter exclusions"
      echo "  C) Continue anyway"
      echo "  A) Abort to main menu"
      read -r -p "Enter choice (R/C/A): " CH
      [[ -n "${CH:-}" ]] || { msg_no_input; return 1; }
      case "${CH^^}" in
        R) echo ""; continue ;;
        C) echo "Continuing with operator override."; echo ""; break ;;
        A) msg_abort; return 1 ;;
        *) echo "Invalid choice; re-entering exclusions."; echo ""; continue ;;
      esac
    else
      echo "Exclusion resolution PASSED (no warnings)."
      echo ""
      break
    fi
  done

  # -------- Candidate generation (post-exclusions) --------
  FIND_CMD=(find "$BASE" -xdev -type f)

  [[ -n "${EXCLUDE_OWNER_UID:-}" ]] && FIND_CMD+=( ! -uid "$EXCLUDE_OWNER_UID" )
  for xf in "${EXCLUDE_FILES[@]}"; do FIND_CMD+=( ! -path "$xf" ); done
  for xd in "${EXCLUDE_DIRS[@]}"; do FIND_CMD+=( ! -path "$xd" ! -path "$xd/*" ); done

  FIND_CMD+=( -print0 )
  emit_candidates(){ "${FIND_CMD[@]}" 2>/dev/null || true; }

  echo "Scanning candidate files (post-exclusions)..."
  TOTAL_FOUND=0
  while IFS= read -r -d '' _; do ((TOTAL_FOUND++)) || true; done < <(emit_candidates)
  echo "Total candidates (after exclusions): $TOTAL_FOUND"
  echo ""

  [[ "$TOTAL_FOUND" -gt 0 ]] || { echo "No candidate files found. Returning to menu."; echo ""; return 1; }

  # -------- Candidate Review Phase (NEW) --------
  CANDIDATE_LOG="/tmp/${SAFE_REQ}_candidate_files.txt"
  emit_candidates | tr '\0' '\n' > "$CANDIDATE_LOG"

  echo "Candidate file list saved to:"
  echo "  $CANDIDATE_LOG"
  echo ""
  echo "Preview of candidate files (first 20):"
  head -n 20 "$CANDIDATE_LOG" | sed 's/^/  /'
  if [[ "$TOTAL_FOUND" -gt 20 ]]; then
    echo "  ... ($((TOTAL_FOUND - 20)) more files)"
  fi
  echo ""

  echo "FINAL CONFIRMATION (two-step):"
  echo "1) Review the full list in: $CANDIDATE_LOG"
  echo "2) Type 'CONFIRM' to acknowledge the list is correct"
  echo "3) Then type 'YES' to execute deletion"
  echo ""

  read -r -p "Type 'CONFIRM' to acknowledge candidate list (or anything else to abort): " ACK
  if [[ "${ACK:-}" != "CONFIRM" ]]; then
    echo "Deletion aborted by operator after review."
    echo ""
    return 1
  fi

  # Keep the classic YES gate as final safety check
  confirm_yes_or_menu || return 1

  echo ""
  echo "Deleting files now..."
  DELETED=0
  FAILED=0
  FAILED_LOG="$(mktemp "/tmp/isi_failed_${SAFE_REQ}.XXXX")"

  if [[ "${WORM_CHECK_MODE^^}" == "STRICT" ]]; then
    echo "STRICT mode: prechecking WORM state using isi worm files view (may be slow)..."
    while IFS= read -r -d '' f; do
      state="$(worm_state_of "$f")"
      if [[ "$state" == "COMMITTED" ]]; then
        if isi worm files delete -f "$f"; then
          ((DELETED++)) || true
        else
          ((FAILED++)) || true
          printf '%s\t%s\n' "$f" "DELETE_FAILED" >> "$FAILED_LOG"
        fi
      else
        ((FAILED++)) || true
        printf '%s\t%s\n' "$f" "$state" >> "$FAILED_LOG"
      fi
    done < <(emit_candidates)
  else
    echo "FAST mode: attempting delete directly; failures are logged."
    while IFS= read -r -d '' f; do
      if isi worm files delete -f "$f"; then
        ((DELETED++)) || true
      else
        ((FAILED++)) || true
        printf '%s\t%s\n' "$f" "DELETE_FAILED_OR_NOT_COMMITTED" >> "$FAILED_LOG"
      fi
    done < <(emit_candidates)
  fi

  echo ""
  echo "Deletion complete. Deleted=$DELETED Failed=$FAILED"
  if [[ "$FAILED" -gt 0 ]]; then
    echo "Failures saved to: $FAILED_LOG"
    echo "Showing first 20 failures (path<TAB>reason/state):"
    head -n 20 "$FAILED_LOG" | sed 's/^/  /'
  fi

  if [[ "$MODE" == "2" ]]; then
    echo ""
    echo "Directory mode: removing EMPTY directories under BASE..."
    find "$BASE" -xdev -type d -empty -mindepth 1 -delete 2>/dev/null || true
    echo "Attempting to remove BASE itself if empty..."
    rmdir "$BASE" 2>/dev/null || true
    echo "Directory cleanup done."
  fi

  echo ""
  echo "Returning to main menu..."
  echo ""
  return 0
}

# ---------- MAIN MENU ----------
while true; do
  echo "==================== MAIN MENU ===================="
  echo "  0) Delete a SINGLE FILE (one full path)"
  echo "  1) Delete FILES under a BASE path (with exclusions)"
  echo "  2) Delete a DIRECTORY (delete COMMITTED files under it, then cleanup empty dirs)"
  echo "  3) EXIT"
  echo "==================================================="
  read -r -p "Enter choice (0/1/2/3): " MODE
  [[ -n "${MODE:-}" ]] || { msg_no_input; continue; }

  case "$MODE" in
    0)
      read -r -p "Enter FULL file path to delete: " ONE_FILE
      [[ -n "${ONE_FILE:-}" ]] || { msg_no_input; continue; }
      [[ -f "$ONE_FILE" ]] || { echo "ERROR: Not a file or does not exist: $ONE_FILE"; echo ""; continue; }
      echo ""
      echo "This will run: isi worm files delete -f \"$ONE_FILE\""
      echo ""
      read -r -p "Type 'CONFIRM' then 'YES' at the next prompt to delete this file. Type anything else to abort: " ACK1
      [[ "${ACK1:-}" == "CONFIRM" ]] || { echo "Not confirmed. Returning to menu."; echo ""; continue; }
      confirm_yes_or_menu || continue
      if isi worm files delete -f "$ONE_FILE"; then
        echo "Deleted successfully: $ONE_FILE"
      else
        echo "ERROR: Delete failed for: $ONE_FILE"
      fi
      echo ""
      ;;
    1) run_base_delete "1" "FILES_ONLY" || true ;;
    2) run_base_delete "2" "DELETE_DIRECTORY" || true ;;
    3)
      echo "Exiting. Log file: $LOGFILE"
      echo "Ended : $(date '+%Y-%m-%d %H:%M:%S %z')"
      exit 0
      ;;
    *)
      echo "WARNING: Invalid choice. Please select 0/1/2/3."
      echo ""
      ;;
  esac
done
