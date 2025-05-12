#!/bin/bash
# wayback_scraper.sh - Wayback Machine URL Extraction Tool
# This script queries the Internet Archive's Wayback Machine for a given domain,
# extracts all archived URLs, filters and deduplicates them, and saves the results.
# 
# Author: Claude
# Date: May 12, 2025
# Requirements: curl, jq

set -o errexit
set -o nounset
set -o pipefail

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display usage information
usage() {
    echo -e "${BLUE}Usage:${NC} $0 <domain>"
    echo -e "Example: $0 example.com"
    echo
    echo -e "${BLUE}Description:${NC}"
    echo "  Queries the Wayback Machine for archived URLs of the specified domain,"
    echo "  extracts all URLs (including subdomains), filters and deduplicates them,"
    echo "  and saves the results to a .txt file named after the target domain."
    echo
    echo -e "${BLUE}Requirements:${NC}"
    echo "  - curl: for API requests"
    echo "  - jq: for JSON parsing"
    exit 1
}

# Function to check if required tools are installed
check_dependencies() {
    echo -e "${BLUE}[*] Checking dependencies...${NC}"
    for cmd in curl jq; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}[!] Error: $cmd is not installed${NC}"
            echo -e "    Please install it with: apt-get install $cmd"
            exit 1
        fi
    done
    echo -e "${GREEN}[+] All dependencies satisfied${NC}"
}

# Function to validate domain format
validate_domain() {
    local domain="$1"
    # Basic domain validation regex
    local domain_regex="^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"
    
    if [[ ! $domain =~ $domain_regex ]]; then
        echo -e "${RED}[!] Error: Invalid domain format${NC}"
        echo -e "    Please provide a valid domain (e.g., example.com)"
        exit 1
    fi
}

# Function to query the Wayback Machine API
query_wayback_machine() {
    local domain="$1"
    local api_url="https://web.archive.org/cdx/search/cdx"
    
    echo -e "${BLUE}[*] Querying Wayback Machine for domain: $domain${NC}"
    echo -e "${YELLOW}[*] This may take some time depending on the number of archived URLs...${NC}"
    
    # Parameters:
    # - url: the domain to search for
    # - output: return format (json in this case)
    # - fl: fields to return (original url and timestamp)
    # - collapse: collapse duplicate URLs
    # - matchType: prefix match to include all paths
    local response=$(curl -s "$api_url?url=$domain&output=json&fl=original,timestamp&collapse=urlkey&matchType=prefix")
    
    # Check if response is valid JSON
    if ! echo "$response" | jq empty 2>/dev/null; then
        echo -e "${RED}[!] Error: Invalid JSON response from Wayback Machine API${NC}"
        echo -e "${YELLOW}[*] Falling back to text format...${NC}"
        
        # Fall back to CSV format instead of JSON
        curl -s "$api_url?url=$domain&output=csv&fl=original,timestamp&collapse=urlkey&matchType=prefix" | tail -n +2 > "${domain}_raw_urls.txt"
        cat "${domain}_raw_urls.txt"
        return
    fi
    
    # Process valid JSON response
    echo "$response" | jq -r '.[] | select(. != ["original", "timestamp"])'
}

# Function to extract and process URLs
process_urls() {
    local input="$1"
    local domain="$2"
    local output_file="${domain}_wayback_urls.txt"
    local temp_file=$(mktemp)
    
    echo -e "${BLUE}[*] Processing URLs...${NC}"
    
    # Check if we're working with the raw text file (fallback method)
    if [[ -f "${domain}_raw_urls.txt" ]]; then
        echo -e "${YELLOW}[*] Processing URLs from raw format...${NC}"
        while IFS=',' read -r url timestamp || [[ -n "$url" ]]; do
            # Remove any surrounding quotes if present
            url=$(echo "$url" | sed 's/^"//;s/"$//')
            timestamp=$(echo "$timestamp" | sed 's/^"//;s/"$//')
            # Add URL to temp file with timestamp as a comment
            echo "$url # archived on $(date -d "${timestamp:0:4}-${timestamp:6:2}-${timestamp:8:2}" "+%Y-%m-%d" 2>/dev/null || echo "date unknown")" >> "$temp_file"
        done < "${domain}_raw_urls.txt"
        # Clean up the raw file
        rm -f "${domain}_raw_urls.txt"
    else
        # Parse JSON array and extract original URLs (first element of each inner array)
        echo "$input" | while read -r line; do
            # Skip empty lines
            [[ -z "$line" ]] && continue
            
            # Try to parse JSON, if it fails, treat as raw data
            if url=$(echo "$line" | jq -r '.[0]' 2>/dev/null) && [[ "$url" != "null" ]]; then
                timestamp=$(echo "$line" | jq -r '.[1]' 2>/dev/null)
                # Add URL to temp file with timestamp as a comment
                echo "$url # archived on $(date -d "${timestamp:0:4}-${timestamp:4:2}-${timestamp:6:2}" "+%Y-%m-%d" 2>/dev/null || echo "date unknown")" >> "$temp_file"
            elif [[ "$line" == *","* ]]; then
                # Fallback for raw CSV format
                url=$(echo "$line" | cut -d ',' -f1)
                timestamp=$(echo "$line" | cut -d ',' -f2)
                echo "$url # archived on $(date -d "${timestamp:0:4}-${timestamp:4:2}-${timestamp:6:2}" "+%Y-%m-%d" 2>/dev/null || echo "date unknown")" >> "$temp_file"
            fi
        done
    fi
    
    # Sort and remove duplicates while preserving the newest archive date
    if [[ -s "$temp_file" ]]; then
        sort -u "$temp_file" > "$output_file"
        local count=$(wc -l < "$output_file")
        echo -e "${GREEN}[+] Successfully extracted $count unique URLs${NC}"
        echo -e "${GREEN}[+] Results saved to: $output_file${NC}"
    else
        echo -e "${YELLOW}[!] No archived URLs found for $domain${NC}"
        echo "No URLs found" > "$output_file"
    fi
    
    # Clean up temp file
    rm -f "$temp_file"
}

# Function to analyze results
analyze_results() {
    local domain="$1"
    local output_file="${domain}_wayback_urls.txt"
    
    if [[ ! -f "$output_file" || ! -s "$output_file" || $(grep -c "No URLs found" "$output_file") -eq 1 ]]; then
        echo -e "${YELLOW}[!] No analysis available - no URLs found${NC}"
        return
    fi
    
    echo -e "${BLUE}[*] Analyzing results...${NC}"
    
    # Count unique subdomains
    local subdomains=$(grep -oE 'https?://[^/]+' "$output_file" | sort -u | wc -l)
    echo -e "${GREEN}[+] Unique domains/subdomains found: $subdomains${NC}"
    
    # Find common file extensions
    echo -e "${BLUE}[*] Common file extensions found:${NC}"
    grep -oE '\.[^/.]+$' "$output_file" | sort | uniq -c | sort -nr | head -5 | while read count ext; do
        echo -e "    ${YELLOW}$ext:${NC} $count files"
    done
}

# Main function
main() {
    # Display banner
    echo -e "${BLUE}=========================================================${NC}"
    echo -e "${BLUE}              WAYBACK MACHINE URL EXTRACTOR             ${NC}"
    echo -e "${BLUE}=========================================================${NC}"
    
    # Check if a domain was provided
    if [[ $# -ne 1 ]]; then
        usage
    fi
    
    # Remove http:// or https:// if present
    domain=$(echo "$1" | sed -E 's|^https?://||')
    
    # Check dependencies
    check_dependencies
    
    # Validate domain
    validate_domain "$domain"
    
    # Query the Wayback Machine
    wayback_data=$(query_wayback_machine "$domain")
    
    # Process URLs
    process_urls "$wayback_data" "$domain"
    
    # Analyze results
    analyze_results "$domain"
    
    echo -e "${BLUE}=========================================================${NC}"
    echo -e "${GREEN}[+] Operation completed successfully${NC}"
}

# Execute main function with all arguments
main "$@"
