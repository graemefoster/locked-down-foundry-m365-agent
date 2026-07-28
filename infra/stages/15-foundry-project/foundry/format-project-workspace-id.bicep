/*
Reformat the project workspace id into a canonical dashed GUID.

Foundry returns the project's internal workspace id as a 32-char hex string with no dashes.
Several downstream role assignments need it as a real GUID: the blob container names Foundry
provisions are prefixed with this workspace id, so the container-scope Storage/Cosmos role
assignments (rbac/storage-container + cosmos-container) build their scope/condition strings
from it. This module just inserts the 8-4-4-4-12 dashes and returns the result.
*/

param projectWorkspaceId string

var part1 = substring(projectWorkspaceId, 0, 8)    // First 8 characters
var part2 = substring(projectWorkspaceId, 8, 4)    // Next 4 characters
var part3 = substring(projectWorkspaceId, 12, 4)   // Next 4 characters
var part4 = substring(projectWorkspaceId, 16, 4)   // Next 4 characters
var part5 = substring(projectWorkspaceId, 20, 12)  // Remaining 12 characters

var formattedGuid = '${part1}-${part2}-${part3}-${part4}-${part5}'

output projectWorkspaceIdGuid string = formattedGuid
