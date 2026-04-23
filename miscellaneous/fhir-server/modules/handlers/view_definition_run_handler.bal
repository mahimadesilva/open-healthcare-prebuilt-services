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

import mahima_de_silva/sof_postgres;

# Execute the SQL-on-FHIR `ViewDefinition/$run` operation.
#
# Accepts a FHIR `Parameters` resource carrying a `viewResource` entry.
# Transpiles the ViewDefinition to PostgreSQL via `sof_postgres:generateQuery`,
# runs it against the shared `jdbc:Client`, and returns the rows as a JSON array.
#
# Only supported against a PostgreSQL backend; H2 returns 501.
# Only `_format=json` is supported; other formats return 400.
# `viewReference` is rejected because this server does not store ViewDefinitions.
#
# + jdbcClient - Shared JDBC client
# + params - FHIR Parameters resource containing the viewResource entry
# + return - Response with JSON rows, or a FHIR error
public isolated function performViewDefinitionRun(jdbc:Client? jdbcClient, international401:Parameters params)
        returns http:Response|r4:OperationOutcome|r4:FHIRError {

    log:printDebug("ViewDefinition/$run - Start Execution");

    string normalizedDbType = dbType.toLowerAscii().trim();
    if normalizedDbType != "postgresql" && normalizedDbType != "postgres" {
        return r4:createFHIRError(
                string `This endpoint is only supported on PostgreSQL. Current dbType: ${dbType}`,
                r4:ERROR, r4:PROCESSING_NOT_SUPPORTED,
                httpStatusCode = http:STATUS_BAD_REQUEST);
    }

    do {
        jdbc:Client validatedClient = check utils:getValidatedJdbcClient(jdbcClient);

        ViewRunInputs|r4:FHIRError extracted = extractRunInputsFromParameters(<map<json>>params.toJson());
        if extracted is r4:FHIRError {
            return extracted;
        }
        json? viewJson = extracted.viewDef;
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

        // Pre-quote identifiers. The per-resource Postgres tables are created with
        // quoted PascalCase names and an uppercase "RESOURCE_JSON" column; without
        // quoting, Postgres folds identifiers to lowercase and the query fails.
        sof_postgres:TranspilerContext ctx = {
            resourceColumn: "\"RESOURCE_JSON\"",
            tableName: string `"${viewResourceType}Table"`,
            filterByResourceType: false
        };

        string|error sqlQuery = sof_postgres:generateQuery(viewJson, ctx);
        if sqlQuery is error {
            return r4:createFHIRError(
                    string `Failed to transpile ViewDefinition to SQL: ${sqlQuery.message()}`,
                    r4:ERROR, r4:INVALID,
                    httpStatusCode = http:STATUS_BAD_REQUEST);
        }
        log:printDebug(string `ViewDefinition/$viewdefinition-run - SQL: ${sqlQuery}`);

        stream<record {}, error?> rowStream = validatedClient->query(new utils:RawSQLQuery(sqlQuery));
        record {}[]|error allRows = from record {} row in rowStream
            select row;
        if allRows is error {
            return r4:createFHIRError(
                    string `Failed to execute ViewDefinition query: ${allRows.message()}`,
                    r4:ERROR, r4:PROCESSING,
                    httpStatusCode = http:STATUS_INTERNAL_SERVER_ERROR);
        }

        json[] rows = [];
        foreach record {} row in allRows {
            rows.push(row.toJson());
        }

        http:Response response = new;
        response.statusCode = http:STATUS_OK;
        response.setHeader("Content-Type", "application/json");
        response.setJsonPayload(rows);
        return response;
    } on fail error e {
        log:printError(string `ViewDefinition/$viewdefinition-run failed: ${e.message()}`);
        return r4:createFHIRError(
                string `ViewDefinition/$viewdefinition-run failed: ${e.message()}`,
                r4:ERROR, r4:PROCESSING,
                httpStatusCode = http:STATUS_INTERNAL_SERVER_ERROR);
    }
}

type ViewRunInputs record {|
    json viewDef;
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

    json? viewJson = ();
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
                viewJson = resField;
            }
        } else if nameField == "viewReference" {
            return r4:createFHIRError(
                    "viewReference is not supported by this server. Use viewResource to supply a ViewDefinition inline.",
                    r4:ERROR, r4:PROCESSING_NOT_SUPPORTED,
                    httpStatusCode = http:STATUS_BAD_REQUEST);
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

    if viewJson is () {
        return r4:createFHIRError(
                "Missing required 'viewResource' parameter",
                r4:ERROR, r4:INVALID,
                httpStatusCode = http:STATUS_BAD_REQUEST);
    }

    return {viewDef: viewJson, format: format};
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
