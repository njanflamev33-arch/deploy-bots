#!/bin/bash
# XeloraCloud Installation Validator
# Run this to check if install.sh has syntax errors

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   XeloraCloud Installation Script Validator         ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo

# Check if install.sh exists
if [ ! -f "install.sh" ]; then
    echo -e "${RED}✗ install.sh not found!${NC}"
    exit 1
fi

echo -e "${YELLOW}Checking install.sh syntax...${NC}"

# Check bash syntax
if bash -n install.sh 2>&1 | grep -q "error"; then
    echo -e "${RED}✗ Syntax errors found:${NC}"
    bash -n install.sh
    exit 1
else
    echo -e "${GREEN}✓ No syntax errors found!${NC}"
fi

# Check for common issues
echo -e "\n${YELLOW}Checking for common issues...${NC}"

# Check for proper shebang
if head -n 1 install.sh | grep -q "^#!/bin/bash"; then
    echo -e "${GREEN}✓ Shebang correct${NC}"
else
    echo -e "${RED}✗ Missing or incorrect shebang${NC}"
fi

# Check for executable permissions
if [ -x "install.sh" ]; then
    echo -e "${GREEN}✓ Script is executable${NC}"
else
    echo -e "${YELLOW}⚠ Script is not executable (run: chmod +x install.sh)${NC}"
fi

# Count functions
func_count=$(grep -c "^[a-z_]*() {" install.sh)
echo -e "${GREEN}✓ Found ${func_count} functions${NC}"

# Check for EOF markers
eof_count=$(grep -c "^EOF$" install.sh)
if [ "$eof_count" -gt 0 ]; then
    echo -e "${GREEN}✓ ${eof_count} heredoc blocks found${NC}"
fi

# Check file size
file_size=$(wc -c < install.sh)
echo -e "${GREEN}✓ Script size: ${file_size} bytes${NC}"

echo
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              Validation Complete! ✓                  ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${GREEN}Your install.sh is ready to use!${NC}"
echo -e "Run with: ${CYAN}sudo ./install.sh${NC}"
echo
