*** Settings ***
Library           RequestsLibrary
Resource          ../resources/variables.robot
Resource          ../resources/keyword.robot

*** Test Cases ***
Deploy Blockchain Nodes
    [Documentation]    Deploys blockchain nodes and tests their REST APIs.
    Start Docker Container    ${DOCKER_IMAGE}    node1    ${NODES_PORT}
    Start Docker Container    ${DOCKER_IMAGE}    node2    ${NODES_PORT}
    Wait For Nodes To Be Ready

Test Node Health
    [Documentation]    Tests the health of the blockchain nodes.
    Create Session    node1    http://localhost:${NODES_PORT}
    ${response}=      Get Request    node1    /health
    ...    uest    node1    /health
    Should Be Equal    ${response.status_code}    200
    Should Be Equal    ${response.json()['status']}    ok

    Create Session    node2    http://localhost:${NODES_PORT}
    ${response}=      Get Request    node2    /health
    Should Be Equal    ${response.status_code}    200
    Should Be Equal    ${response.json()['status']}    ok

Teardown
    [Documentation]    Stops and removes Docker containers after tests.
    Stop Docker Container    node1
    Stop Docker Container    node2