import ballerina/io;

import mahima_de_silva/sof_postgres;
import mahima_de_silva/sql_on_fhir_lib;

public function sampleSqlonFhir() returns error? {
    // check processPatients();
    // check processConditions();
    json[] basicResources = [
        {
            "resourceType": "Patient",
            "id": "pt1",
            "name": [
                {
                    "family": "F1"
                }
            ],
            "active": true
        },
        {
            "resourceType": "Patient",
            "id": "pt2",
            "name": [
                {
                    "family": "F2"
                }
            ],
            "active": false
        },
        {
            "resourceType": "Patient",
            "id": "pt3"
        }
    ];
    json viewJson = {
        "resource": "Patient",
        "status": "active",
        "select": [
            {
                "column": [
                    {
                        "name": "id",
                        "path": "id",
                        "type": "id"
                    }
                ]
            }
        ]
    };

    sof_postgres:TranspilerContext ctx = {
        resourceColumn: "resource_json",
        tableName: "PatientTable",
        filterByResourceType: false
    };
    string viewSql = check sof_postgres:generateQuery(viewJson, ctx);
    io:println(viewSql);
    // SELECT
    // CAST(jsonb_extract_path_text(r.resource_json, 'id') AS VARCHAR(64)) AS "id"
    // FROM PatientTable AS r

    json[] results = check sql_on_fhir_lib:evaluate(basicResources, viewJson);
    io:println(results);
    //     json[] expected = [
    //     {
    //         "id": "pt1"
    //     },
    //     {
    //         "id": "pt2"
    //     },
    //     {
    //         "id": "pt3"
    //     }
    // ];
}
