#!/bin/bash
#set -x

if [ -z "$wrike_token" ]; then
    echo "Error: Missing Wrike token !"
    exit 1
fi


#########################################
# Get interesting infos from commit log #
#########################################
git fetch --tags
commit_lines=$(git log --pretty=%b $oldest_commit..$newest_commit | grep -Po "(resolve|end) (#\d+,?)+") # sed removes empty lines

echo "########################"
echo "> search commit between $last_tag and $head_tag"
echo "- found:"
printf "$commit_lines \n"
echo "########################"


########################
# Fetch Wrike task ids #
########################

end_ids=""
resolve_ids=""

IFS=$'\n'
for commit in ${commit_lines}; do
    echo "-------------------------"
    echo "> PARSE :" $commit
    #extract method
    method=$(echo $commit | grep -Po "(resolve|end)" )
    echo "- method =" $method

    #extract ids
    id_str=$(echo $commit | grep -Po "(#\d+,?)+")
    echo "- ids =" $id_str

    if [ -z "$method" ] || [ -z "$id_str" ]; then
        continue
    fi

    IFS=',' # word delimiter
    read -ra ADDR <<< "$id_str" # str is read into an array as tokens separated by IFS
    for permalink_id in "${ADDR[@]}"; do # access each element of array
        echo "> REQUEST ID"
        task_json=$(curl -s -g -G -X GET \
            -H "Authorization: bearer $wrike_token" \
            "https://www.wrike.com/api/v4/tasks" \
            --data-urlencode "permalink=https://www.wrike.com/open.htm?id=${permalink_id//#/}"
        )
	      custom_status=$(echo "$task_json" | grep -Po '(?<="customStatusId": ").*?[^\\](?=")')
   	    id=$(echo "$task_json" | grep -Po '(?<="id": ").*?[^\\](?=")')
        if [ "$method" = "end" ] && [ "$custom_status" = "$end_required_status_id" ]; then
            end_ids="$end_ids$id,"
        elif [ $method = "resolve" ] && [ "$custom_status" = "$resolve_required_status_id" ]; then
            resolve_ids="$resolve_ids$id,"
        else
            echo "/!\ skipped because task status is unexpected"
        fi
        echo "- wrike db id =" $id
    done
    IFS=$'\n' # reset to default value after usage
done

IFS=' '

echo "########################"
echo "Extracted end ids : $end_ids"
echo "Extracted resolve ids : $resolve_ids"

#################
# Resolve tasks #
#################

function resolve_task {
    IFS=','
    read -ra ADDR <<< "$1" # str is read into an array as tokens separated by IFS
    for task_id in "${ADDR[@]}"; do # access each element of array
        echo "- $task_id" 
        result=$(curl -g -G -X PUT \
            -H "Authorization: bearer $wrike_token" \
            "https://www.wrike.com/api/v4/tasks/$task_id" \
            -d customStatus=$2 \
            -d "customFields=[{id=$resolved_version_custom_field_id,value=$version}]"
        )
        [ -z "$result" ] && echo "Error !" || echo "OK : $result"
    done
    IFS=' '
}

if [ ! -z "$resolve_ids" ]; then
    echo "########################"
    echo "> resolve tasks"
    resolve_task $resolve_ids $resolve_status_id
fi

if [ ! -z "$end_ids" ]; then
    echo "########################"
    echo "> end tasks"
    resolve_task $end_ids $end_status_id
fi

######################################
# update reviewed version value list #
######################################

echo "########################"
echo "> update version list"

versions=$(curl -s -g -G -X GET \
    -H "Authorization: bearer $wrike_token" \
    "https://www.wrike.com/api/v4/customfields/$reviewed_version_custom_field_id" \
    | tr -d '\n' \
    | grep -Po '(?<="values": \[).*?[^\\](?=\])'
)

result=$(curl -s -g -G -X PUT \
    -H "Authorization: bearer $wrike_token" \
    "https://www.wrike.com/api/v4/customfields/$reviewed_version_custom_field_id" \
    --data-urlencode "settings={values=[\"$version\",${versions//  /}]}"
)

[ -z "$result" ] && echo "Error !" || echo "OK"

echo "Done."
