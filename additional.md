GREEN="\e[1m\e[1;32m" # green color
RED="\e[1m\e[1;31m" # red color
BLUE='\033[0;34m'   # blue color
YELLOW="\e[1m\e[1;33m"  # yellow color
NC="\e[0m"          # no color

function printLine {
  echo "------------------------------------------------------------------------------------"
}

function printGreen {
  echo -e "${GREEN}${1}${NC}"
}

function printRed {
  echo -e "${RED}${1}${NC}"
}

function printBlue {
  echo -e "${BLUE}${1}${NC}"
}

function printYellow {
  echo -e "${YELLOW}${1}${NC}"
}

function addToPath {
  source $HOME/.bash_profile
  PATH_EXIST=$(grep "${1}" $HOME/.bash_profile)
  if [ -z "$PATH_EXIST" ]; then
    echo "export PATH=\$PATH:${1}" >> $HOME/.bash_profile
  fi
}
