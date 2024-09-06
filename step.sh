#!/bin/bash
#set -x

wrike_token="eyJ0dCI6InAiLCJhbGciOiJIUzI1NiIsInR2IjoiMSJ9.eyJkIjoie1wiYVwiOjI2ODg0NDMsXCJpXCI6NzA3OTgwMCxcImNcIjo0NjE5NTkwLFwidVwiOjYzNjU3MDIsXCJyXCI6XCJVU1wiLFwic1wiOltcIldcIixcIkZcIixcIklcIixcIlVcIixcIktcIixcIkNcIixcIkRcIixcIkFcIixcIkxcIixcIlBcIl0sXCJ6XCI6W10sXCJ0XCI6MH0iLCJpYXQiOjE1OTExMDgyMzR9.sJf-6TeCLOvFfpoygdIpc_PdZ6xYAczAwNqHSSNOTjU"
is_debug="true"

oldest_commit="ba6d8dd57e2eef563a4cd7ffef4e7b0c9546c802"
newest_commit="HEAD"

resolve_status_id="prout"
end_status_id="IEACSBN3JMBFHZV6"
resolve_required_status_id="prout"
end_required_status_id="IEACSBN3JMBFKB52"
resolved_version_custom_field_id="prout"
reviewed_version_custom_field_id="prout"


if [ -z "$wrike_token" ]; then
    echo "Error: Missing Wrike token !"
    exit 1
fi

if "$is_debug" = "true"; then
#    set -x
    echo "## DEBUG MODE ##"
    
    echo "# Git version :"
    git --version
    echo "# Start commit :"
    git show $oldest_commit
    echo "# End commit :"
    git show $newest_commit
fi

#########################################
# Get interesting infos from commit log #
#########################################

git fetch --tags --quiet
#MacOS does not support grep -P....  💩
#commit_lines=$(git log --pretty=%b $oldest_commit..$newest_commit | grep -Po "(resolve|end) (#\d+,?)+") # sed removes empty lines
commit_lines=$(git log --pretty=%b "${oldest_commit}".."${newest_commit}" | perl -nle'print $& while m{(resolve|end) (#\d+,?)+}g')


echo "########################"
echo "> search commit between $oldest_commit and $newest_commit"
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
    method=$(echo $commit | perl -nle'print $& while m{(resolve|end)}g')
    echo "- method =" $method

    #extract ids
    id_str=$(echo $commit | perl -nle'print $& while m{(#\d+,?)+}g')
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
            --data-urlencode "permalink=https://www.wrike.com/open.htm?id=${permalink_id//#/}" \
            --data-urlencode 'fields=["customFields"]'
        )
        
        if "$is_debug" = "true"; then
            echo "- result :" $task_json
        fi
	      custom_status=$(echo "$task_json" | perl -nle'print $& while m{(?<="customStatusId": ").*?[^\\](?=")}g')
        echo "- customStatus =" $custom_status
   	    id=$(echo "$task_json" | perl -nle'print $& while m{(?<="id": ").*?[^\\](?=")}g')
   	    tasktype=$(echo "$task_json" | perl -nle'print $& while m{(?<="id": "IEACSBN3JUAGW7JD",).*?[^\\](?=})}g')
   	    
   	    echo "- task type :" $tasktype
   	    
        if [ "$method" = "end" ] && [ "$custom_status" = "$end_required_status_id" ]; then
            end_ids="$end_ids$id,"
        elif [ "$method" = "resolve" ] && [ "$custom_status" = "$resolve_required_status_id" ]; then
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
        result=$(curl -s -g -G -X PUT \
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

exit 0

echo "########################"
echo "> update version list"

versions=$(curl -s -g -G -X GET \
    -H "Authorization: bearer $wrike_token" \
    "https://www.wrike.com/api/v4/customfields/$reviewed_version_custom_field_id" \
    | tr -d '\n' \
    | perl -nle'print $& while m{(?<="values": \[).*?[^\\](?=\])}g'
)

result=$(curl -s -g -G -X PUT \
    -H "Authorization: bearer $wrike_token" \
    "https://www.wrike.com/api/v4/customfields/$reviewed_version_custom_field_id" \
    --data-urlencode "settings={values=[\"$version\",${versions//  /}]}"
)

[ -z "$result" ] && echo "Error !" || echo "OK"

echo "Done."
