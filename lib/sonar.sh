#---------------------------------
# Depends on assert.sh; console.sh
#---------------------------------

SONAR_ANALYSIS_VALIDATION_SONAR_API_STATUS_ERROR=95
SONAR_ANALYSIS_VALIDATION_SONAR_API_RESULT_ERROR=96
SONAR_ANALYSIS_VALIDATION_SONAR_API_UNKNOW_STATUS=97
SONAR_ANALYSIS_VALIDATION_MAX_POOLING_ATTEMPTS_REACHED=98
SONAR_ANALYSIS_VALIDATION_FAILED=1 # Not an error. Validation not passed

# Param pullrequest_id
# Required environment variables:
# - SONARQUBE_USERKEY
# - SONARSCANNER_END_OUTPUT_FILE
# Returns: 
#   0 - Success
#   SONAR_ANALYSIS_VALIDATION_FAILED - Not passed
#   Write report url to output 1
#   Information/Error message goes to output 2
function sonar-analysis-validation
{
	local pullrequest_id=$1

	assert-not-empty pullrequest_id
	assert-not-empty SONARQUBE_USERKEY
	assert-not-empty SONARSCANNER_END_OUTPUT_FILE

	local task_status_url=$(grep \
		'INFO: More about the report processing at ' $SONARSCANNER_END_OUTPUT_FILE | \
		egrep -o 'https?://.*')
	
	local report_url=$(grep \
		'INFO: ANALYSIS SUCCESSFUL, you can browse ' $SONARSCANNER_END_OUTPUT_FILE | \
		egrep -o 'https?://.*')
	
	local sonar_base_url=$(echo $task_status_url | sed -E 's/\/api\/ce\/task\?id=.*//g')
	local pooling_attempts=0
	
	local sonar_task_status_output_file=$(mktemp -t \
		"pr-sonar-val-status-${pullrequest_id}-XXXXXXXX.json")
	
	local sonar_task_result_output_file=$(mktemp -t \
		"pr-sonar-val-result-${pullrequest_id}-XXXXXXXX.json")
	
	local got_result=false
	local return_code=0 # Success

	while ! $got_result :
	do
		if ! curl -u $SONARQUBE_USERKEY: --fail -s $task_status_url -o "$sonar_task_status_output_file"
		then 
			red "Could not read sonar analysis status. Request to '$task_status_url' failed" >&2
			return $SONAR_ANALYSIS_VALIDATION_SONAR_API_STATUS_ERROR
		fi

		#echo "sonar-taks-status ==============================================="
		#cat $sonar_task_status_output_file
		#echo
		#echo "================================================================="

		local sonar_status=$(cat $sonar_task_status_output_file | jq -r -M '.task.status')
		local analysis_id=$(cat $sonar_task_status_output_file | jq -r -M '.task.analysisId')
		local result_url="$sonar_base_url/api/qualitygates/project_status?analysisId=$analysis_id"

		if [ "$sonar_status" != "IN_PROGRESS" ] && [ "$sonar_status" != "PENDING" ]
		then

			echo "Analysis completed!" >&2
			got_result=true

			if [ "$sonar_status" = "SUCCESS" ] 
			then					
				if ! curl -u $SONARQUBE_USERKEY: --fail -s $result_url -o $sonar_task_result_output_file
				then
					red "Could not read sonar analysis result. Request to '$result_url' failed" >&2
					return $SONAR_ANALYSIS_VALIDATION_SONAR_API_RESULT_ERROR
				fi

				#echo "sonar-result ===================================================="
				#cat $sonar_task_result_output_file
				#echo
				#echo "================================================================="

				sonar_result=$(cat $sonar_task_result_output_file | jq -r -M '.projectStatus.status')

				if [ "$sonar_result" = "OK" ]
				then
					green "Sonar analysis succeeded!" >&2
				else
					red "Sonar analysis failed! Result: $sonar_result" >&2
					return_code=$SONAR_ANALYSIS_VALIDATION_FAILED
					#echo "Sonar result:"
					#echo "--------------------------------------"
					#cat $sonar_task_result_output_file
					#echo					
				fi

				echo "$report_url" # Report url on output 1

			else
				red "Sonar analysis task provided an unknow status. Provided status: $sonar_status" >&2
				return $SONAR_ANALYSIS_VALIDATION_SONAR_API_UNKNOW_STATUS
			fi

			echo "Analysis report: $report_url" >&2

		elif [ "$pooling_attempts" -gt "60" ]
		then
			red "Too many pooling attempts, terminating." >&2
			return $SONAR_ANALYSIS_VALIDATION_MAX_POOLING_ATTEMPTS_REACHED
		fi

		rm -f $sonar_task_status_output_file > /dev/null 2>&1
			
		if ! $got_result
		then
			pooling_attempts=$((pooling_attempts+1))
			echo "Status: $sonar_status" >&2
			sleep 1
		fi
	done

	rm -f $sonar_task_result_output_file > /dev/null 2>&1

	return $return_code
}