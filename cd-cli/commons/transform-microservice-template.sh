#!/usr/bin/env bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)


usage() {
      cat <<EOF
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] -p <project-name> -r <aws-region> -m <microcvs-name>
    [-h]                      : this help message
    -p <project-name>         : project name
    -r <aws-region>           : aws region
    -m <microcvs-name>        : microcvs name

EOF
  exit 1
}

parse_params() {
  # default values of variables set from params
  template_file_path=""

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -f | --template-file-path)
      template_file_path="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

   # check required params and arguments
  [[ -z "${template_file_path-}" ]] && usage
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Template File Path:          ${template_file_path}"
}

transformations=("CfTransform")

parse_params "$@"
dump_params
tmp=$(mktemp)
flag=0

to_add=()
for t in "${transformations[@]}"; do
  if ! grep -qE "^[[:space:]]*-[[:space:]]+$t\$" "$template_file_path"; then
    to_add+=("$t")
  fi
done

if [ ${#to_add[@]} -eq 0 ]; then
  echo "No trasform to add"
  exit 0
fi

if grep -qE '^\s*Transform:\s*$' "$template_file_path"; then
  echo "Transform: found"
  while IFS= read -r line; do
    if [[ $flag -eq 1 ]]; then

      indent=$(echo "$line" | grep -o '^[[:space:]]*')

      for transform in "${to_add[@]}"; do
        echo "${indent}- $transform" >> "$tmp"
      done

      echo "$line" >> "$tmp"
      flag=2
      continue
    fi

    echo "$line" >> "$tmp"

    if [[ "$line" =~ ^[[:space:]]*Transform:[[:space:]]*$ ]]; then
      flag=1
    fi

  done < "$template_file_path"
  mv "$tmp" "$template_file_path"
else
  echo "Transform: NON trovato"

  inserted=0
  lines=()  # array per buffering

  while IFS= read -r line; do
    if [[ $inserted -eq 0 && "$line" =~ ^[[:space:]]*Parameters:[[:space:]]*$ ]]; then
      lines+=("$line")  # mantieni la riga "Parameters:"
      
      # Trova l'indentazione della prima riga non vuota dopo Parameters:
      while IFS= read -r next_line; do
        lines+=("$next_line")
        if [[ -n "$next_line" ]]; then
          indent=$(echo "$next_line" | grep -o '^[[:space:]]*')
          break
        fi
      done

      # Scrivi blocco Transform
      echo "Transform:" >> "$tmp"
      for transform in "${to_add[@]}"; do
        echo "${indent}- $transform" >> "$tmp"
      done
      echo "" >> "$tmp"

      # Ora scrivi le righe buffered (Parameters + la successiva)
      for l in "${lines[@]}"; do
        echo "$l" >> "$tmp"
      done

      inserted=1
      continue
    fi

    echo "$line" >> "$tmp"
  done < "$template_file_path"

  mv "$tmp" "$template_file_path"
fi

echo "Tranform Added Successfull"
echo ""
echo ""
exit 0