*** Settings ***
Library    Process

*** Keywords ***
Start Docker Container
    [Arguments]    ${image}    ${container_name}    ${port}
    Run Process    docker    run -d --name ${container_name} -p ${port}:2304 ${image}

Stop Docker Container
    [Arguments]    ${container_name}
    Run Process    docker    stop ${container_name}
    Run Process    docker    rm ${container_name}

Wait For Nodes To Be Ready
    Sleep    10s