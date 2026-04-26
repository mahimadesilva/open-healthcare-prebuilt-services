// Copyright (c) 2025, WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina_fhir_server.utils;

import ballerina/http;
import ballerina/log;
import ballerinax/health.fhir.r4;
import ballerinax/health.fhir.r4.international401;
import ballerinax/java.jdbc;

import mahima_de_silva/sql_on_fhir_lib;
import mahima_de_silva/sql_on_fhir_lib.in_memory_runner as sof_im_runner;
import mahima_de_silva/sql_on_fhir_lib.pg_db_runner as sof_pg_runner;

# Execute the SQL-on-FHIR `ViewDefinition/$run` operation.
#
# Accepts a FHIR `Parameters` resource with the following entries:
# - `viewResource` (0..1): inline ViewDefinition JSON — exclusive with `viewReference`
# - `viewReference` (0..1): reference to a stored ViewDefinition e.g. `ViewDefinition/id` — exclusive with `viewResource`
# - `resource` (0..*): inline FHIR resources to evaluate against; if absent, runs against stored DB data
# - `_format` (0..1): output format; only `json` is supported
#
# If `resource` parameters are supplied the ViewDefinition is evaluated in-memory via
# `sql_on_fhir_lib:evaluate` and works with any dbType.
# If no `resource` parameters are supplied the ViewDefinition is transpiled to PostgreSQL SQL
# and executed against the shared `jdbc:Client`; only PostgreSQL is supported for this path.
#
# + jdbcClient - Shared JDBC client
# + params - FHIR Parameters resource
# + return - Response with JSON rows, or a FHIR error
public isolated function performViewDefinitionRun(jdbc:Client? jdbcClient, international401:Parameters params)
        returns http:Response|r4:OperationOutcome|r4:FHIRError {

    log:printDebug("ViewDefinition/$run - Start Execution");

    do {
        ViewRunInputs|r4:FHIRError extracted = extractRunInputsFromParameters(<map<json>>params.toJson());
        if extracted is r4:FHIRError {
            return extracted;
        }

        // Validate mutual exclusivity of viewResource / viewReference
        if extracted.viewDef !is () && extracted.viewRef !is () {
            return r4:createFHIRError(
                    "Cannot specify both viewResource and viewReference — supply exactly one",
                    r4:ERROR, r4:INVALID,
                    httpStatusCode = http:STATUS_BAD_REQUEST);
        }
        if extracted.viewDef is () && extracted.viewRef is () {
            return r4:createFHIRError(
                    "Must specify either viewResource or viewReference",
                    r4:ERROR, r4:INVALID,
                    httpStatusCode = http:STATUS_BAD_REQUEST);
        }

        // Resolve the ViewDefinition JSON
        json viewJson;
        if extracted.viewDef !is () {
            viewJson = <json>extracted.viewDef;
        } else {
            string rawRef = <string>extracted.viewRef;
            string[] parts = re `/`.split(rawRef);
            if parts.length() < 2 || parts[0] != "ViewDefinition" || parts[parts.length() - 1].length() == 0 {
                return r4:createFHIRError(
                        string `Invalid viewReference format '${rawRef}'. Expected 'ViewDefinition/{id}'`,
                        r4:ERROR, r4:INVALID,
                        httpStatusCode = http:STATUS_BAD_REQUEST);
            }
            string vdId = parts[parts.length() - 1];

            ReadHandler readHandler = new;
            json|error vdResource = readHandler.readResource(jdbcClient, "ViewDefinition", vdId);
            if vdResource is error {
                return r4:createFHIRError(
                        string `ViewDefinition/${vdId} not found: ${vdResource.message()}`,
                        r4:ERROR, r4:PROCESSING_NOT_FOUND,
                        httpStatusCode = http:STATUS_NOT_FOUND);
            }
            viewJson = vdResource;
        }

        // Validate format
        string? requestedFormat = extracted.format;
        if requestedFormat is string {
            string fmt = requestedFormat.toLowerAscii().trim();
            if fmt != "json" && fmt != "application/json" && fmt != "application/fhir+json" {
                return r4:createFHIRError(
                        string `Only _format=json is supported. Got: ${requestedFormat}`,
                        r4:ERROR, r4:PROCESSING_NOT_SUPPORTED,
                        httpStatusCode = http:STATUS_BAD_REQUEST);
            }
        }

        // Validate ViewDefinition structure
        if viewJson !is map<json> {
            return r4:createFHIRError(
                    "ViewDefinition must be a JSON object",
                    r4:ERROR, r4:INVALID,
                    httpStatusCode = http:STATUS_BAD_REQUEST);
        }
        json viewResField = viewJson["resource"] ?: ();
        if viewResField !is string {
            return r4:createFHIRError(
                    "ViewDefinition is missing required 'resource' field",
                    r4:ERROR, r4:INVALID,
                    httpStatusCode = http:STATUS_BAD_REQUEST);
        }
        string viewResourceType = viewResField;
        if !isValidResourceTypeName(viewResourceType) {
            return r4:createFHIRError(
                    string `Invalid ViewDefinition.resource value: ${viewResourceType}`,
                    r4:ERROR, r4:INVALID,
                    httpStatusCode = http:STATUS_BAD_REQUEST);
        }

        json[] rows = [];

        if extracted.resources.length() > 0 {
            // In-memory evaluation path — works with any dbType
            sql_on_fhir_lib:ViewDefinition|error viewDef = viewJson.cloneWithType(sql_on_fhir_lib:ViewDefinition);
            if viewDef is error {
                return r4:createFHIRError(
                        string `Invalid ViewDefinition structure: ${viewDef.message()}`,
                        r4:ERROR, r4:INVALID,
                        httpStatusCode = http:STATUS_BAD_REQUEST);
            }
            json[]|error evalResult = sof_im_runner:evaluate(extracted.resources, viewDef);
            if evalResult is error {
                return r4:createFHIRError(
                        string `Failed to evaluate ViewDefinition: ${evalResult.message()}`,
                        r4:ERROR, r4:PROCESSING,
                        httpStatusCode = http:STATUS_INTERNAL_SERVER_ERROR);
            }
            rows = evalResult;
        } else {
            // SQL-against-DB path — PostgreSQL only
            string normalizedDbType = dbType.toLowerAscii().trim();
            if normalizedDbType != "postgresql" && normalizedDbType != "postgres" {
                return r4:createFHIRError(
                        string `Running against stored data is only supported on PostgreSQL. Current dbType: ${dbType}`,
                        r4:ERROR, r4:PROCESSING_NOT_SUPPORTED,
                        httpStatusCode = http:STATUS_NOT_IMPLEMENTED);
            }

            jdbc:Client validatedClient = check utils:getValidatedJdbcClient(jdbcClient);

            // Pre-quote identifiers to match the PascalCase table/column names created by the schema.
            sof_pg_runner:TranspilerContext ctx = {
                resourceColumn: "\"RESOURCE_JSON\"",
                tableName: string `"${viewResourceType}Table"`,
                filterByResourceType: false
            };

            string|error sqlQuery = sof_pg_runner:generateQuery(viewJson, ctx);
            if sqlQuery is error {
                return r4:createFHIRError(
                        string `Failed to transpile ViewDefinition to SQL: ${sqlQuery.message()}`,
                        r4:ERROR, r4:INVALID,
                        httpStatusCode = http:STATUS_BAD_REQUEST);
            }
            log:printDebug(string `ViewDefinition/$run - SQL: ${sqlQuery}`);

            stream<record {}, error?> rowStream = validatedClient->query(new utils:RawSQLQuery(sqlQuery));
            record {}[]|error allRows = from record {} row in rowStream
                select row;
            if allRows is error {
                return r4:createFHIRError(
                        string `Failed to execute ViewDefinition query: ${allRows.message()}`,
                        r4:ERROR, r4:PROCESSING,
                        httpStatusCode = http:STATUS_INTERNAL_SERVER_ERROR);
            }
            foreach record {} row in allRows {
                rows.push(row.toJson());
            }
        }

        http:Response response = new;
        response.statusCode = http:STATUS_OK;
        response.setHeader("Content-Type", "application/json");
        response.setJsonPayload(rows);
        return response;

    } on fail error e {
        log:printError(string `ViewDefinition/$run failed: ${e.message()}`);
        return r4:createFHIRError(
                string `ViewDefinition/$run failed: ${e.message()}`,
                r4:ERROR, r4:PROCESSING,
                httpStatusCode = http:STATUS_INTERNAL_SERVER_ERROR);
    }
}

type ViewRunInputs record {|
    json? viewDef;
    string? viewRef;
    json[] resources;
    string? format;
|};

isolated function extractRunInputsFromParameters(map<json> parametersBody) returns ViewRunInputs|r4:FHIRError {
    json paramsField = parametersBody["parameter"] ?: ();
    if paramsField !is json[] || paramsField.length() == 0 {
        return r4:createFHIRError(
                "Parameters.parameter is missing or empty",
                r4:ERROR, r4:INVALID,
                httpStatusCode = http:STATUS_BAD_REQUEST);
    }

    json? viewDef = ();
    string? viewRef = ();
    json[] resources = [];
    string? format = ();

    foreach json entry in paramsField {
        if entry !is map<json> {
            continue;
        }
        json nameField = entry["name"] ?: ();
        if nameField !is string {
            continue;
        }

        if nameField == "viewResource" {
            json resField = entry["resource"] ?: ();
            if resField !is () {
                viewDef = resField;
            }
        } else if nameField == "viewReference" {
            json refObj = entry["valueReference"] ?: ();
            if refObj is map<json> {
                json refStr = refObj["reference"] ?: ();
                if refStr is string {
                    viewRef = refStr;
                }
            }
        } else if nameField == "resource" {
            json resField = entry["resource"] ?: ();
            if resField !is () {
                resources.push(resField);
            }
        } else if nameField == "_format" {
            json codeField = entry["valueCode"] ?: ();
            json stringField = entry["valueString"] ?: ();
            if codeField is string {
                format = codeField;
            } else if stringField is string {
                format = stringField;
            }
        }
    }

    return {viewDef, viewRef, resources, format};
}

isolated function isValidResourceTypeName(string name) returns boolean {
    if name.length() == 0 {
        return false;
    }
    // Must start with an uppercase letter, followed by letters/digits only.
    // Prevents SQL injection when the name is spliced into the quoted tableName.
    string:RegExp validPattern = re `^[A-Z][A-Za-z0-9]*$`;
    return validPattern.isFullMatch(name);
}
