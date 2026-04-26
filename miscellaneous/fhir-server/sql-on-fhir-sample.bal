import ballerina/io;

import mahima_de_silva/sql_on_fhir_lib;
import mahima_de_silva/sql_on_fhir_lib.in_memory_runner as sof_im_runner;
import mahima_de_silva/sql_on_fhir_lib.pg_db_runner as sof_pg_runner;

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

    sof_pg_runner:TranspilerContext ctx = {
        resourceColumn: "resource_json",
        tableName: "PatientTable",
        filterByResourceType: false
    };
    string viewSql = check sof_pg_runner:generateQuery(viewJson, ctx);
    io:println(viewSql);
    // SELECT
    // CAST(jsonb_extract_path_text(r.resource_json, 'id') AS VARCHAR(64)) AS "id"
    // FROM PatientTable AS r

    sql_on_fhir_lib:ViewDefinition viewDef = check viewJson.cloneWithType(sql_on_fhir_lib:ViewDefinition);

    json[] results = check sof_im_runner:evaluate(basicResources, viewDef);
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
