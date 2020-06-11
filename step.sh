#!/bin/bash

if [ -z "$wrike_token" ]; then
    echo "Error: Missing Wrike token !"
    exit 1
fi


#########################################
# Get interesting infos from commit log #
#########################################
git fetch --tags
tags=$(git tag -l $tag_prefix* --sort=-version:refname)
head_tag=$(git tag -l $tag_prefix* --sort=-version:refname --points-at HEAD | sed -n '1p') # sed takes the first line
last_tag="master"
for tag in ${tags}; do
    if [ "$tag" != "$head_tag" ]; then
        last_tag=$tag
        break;
    fi
done
commit_lines=$(git log --pretty=%b $last_tag..HEAD | grep -Po "(resolve|end) (#\d+,?)+") # sed removes empty lines

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
        id=$(curl -s -g -G -X GET \
            -H "Authorization: bearer $wrike_token" \
            "https://www.wrike.com/api/v4/tasks" \
            --data-urlencode "permalink=https://www.wrike.com/open.htm?id=${permalink_id//#/}" \
            | grep -Po '(?<="id": ").*?[^\\](?=")'
        )
        if [ "$method" = "end" ]; then
            end_ids="$end_ids$id,"
        elif [ $method = "resolve" ]; then
            resolve_ids="$resolve_ids$id,"
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
    result=$(curl -s -g -G -X PUT \
        -H "Authorization: bearer $wrike_token" \
        "https://www.wrike.com/api/v4/tasks/$1" \
        -d customStatus=$2 \
        -d "customFields=[{id=$resolved_version_custom_field_id,value=$version}]"
    )
    [ -z "$result" ] && echo "Error !" || echo "OK"
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
