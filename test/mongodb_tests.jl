
#
# Tests depend on a running server at localhost:27017,
# and will create a database named "mongoc".
#
# Start a fresh MongoDB instance with:
#
# ```
# $ mkdir db
# $ mongod --dbpath ./db --smallfiles
# ```
#

import Mongoc

using Test
using Dates

const DB_NAME = "mongoc"

@testset "MongoDB" begin

    client = Mongoc.Client()

    @testset "Types" begin
        bson = Mongoc.BSON()
        @test_throws ErrorException Mongoc.Client("////invalid-url")
        @test client.uri == "mongodb://localhost:27017"
        Mongoc.set_appname!(client, "Runtests")
        db = client[DB_NAME]
        coll = db["new_collection"]

        io = IOBuffer()
        show(io, bson)
        show(io, client)
        show(io, db)
        show(io, coll)
        show(io, Mongoc.BSONCode("function() = 1"))
        show(io, Mongoc.QUERY_FLAG_TAILABLE_CURSOR)
    end

    @testset "Connection" begin

        @testset "ping" begin
            bson_ping_result = Mongoc.ping(client)
            @test haskey(bson_ping_result, "ok")
            @test Mongoc.as_json(Mongoc.ping(client)) == """{ "ok" : 1.0 }"""
        end

        @testset "Server Status" begin
            bson_server_status = Mongoc.command_simple(client["admin"], Mongoc.BSON("""{ "serverStatus" : 1 }"""))
            println("Server Mongo Version: ", bson_server_status["version"])
        end

        @testset "error print" begin
            error_happened = false
            try
                Mongoc.command_simple(client["hey"], Mongoc.BSON("""{ "you" : 1 }"""))
            catch e
                println(IOBuffer(), e)
                error_happened = true
            end

            @test error_happened
        end

        @testset "new_collection" begin
            coll = client[DB_NAME]["new_collection"]
            result = push!(coll, Mongoc.BSON("""{ "hello" : "world" }"""))
            @test Mongoc.as_json(result.reply) == """{ "insertedCount" : 1 }"""
            result = push!(coll, Mongoc.BSON("""{ "hey" : "you" }"""))
            @test Mongoc.as_json(result.reply) == """{ "insertedCount" : 1 }"""

            bson = Mongoc.BSON()
            bson["hey"] = "you"

            bson["zero_date"] = DateTime(0)
            bson["date_2018"] = DateTime(2018)

            result = push!(coll, bson)
            @test Mongoc.as_json(result.reply) == """{ "insertedCount" : 1 }"""

            i = 0
            for bson in coll
                @test haskey(bson, "hello") || haskey(bson, "hey")
                i += 1
            end
            @test i == length(coll)

            i = 0
            for bson in Mongoc.find(coll, Mongoc.BSON("""{ "hello" : "world" }"""))
                i += 1
            end
            @test i == 1

            Mongoc.command_simple(coll, Mongoc.BSON("""{ "collStats" : "new_collection" }"""))
            empty!(coll)
        end

        @testset "find_databases" begin
            found = false
            for obj in Mongoc.find_databases(client)
                if obj["name"] == DB_NAME
                    found = true
                end
            end
            @test found

            @test DB_NAME ∈ Mongoc.get_database_names(client)
        end

        @testset "catch cursor error" begin
            # issue #15
            invalid_client = Mongoc.Client("mongodb://invalid_url")
            collection = invalid_client["db_name"]["collection_name"]
            @test_throws ErrorException Mongoc.find_one(collection, Mongoc.BSON(""" { "a" : 1 } """))
        end

        @testset "Binary data" begin
            coll = client[DB_NAME]["new_collection"]
            bsonDoc = Mongoc.BSON()
            testdata = rand(UInt8, 100)
            bsonDoc["someId"] = "1234"
            bsonDoc["bindata"] = testdata
            result = push!(coll, bsonDoc)
            @test Mongoc.as_json(result.reply) == """{ "insertedCount" : 1 }"""

            # read data out and confirm
            selector = Mongoc.BSON("""{ "someId": "1234" }""")
            results = Mongoc.find_one(coll,  selector)

            @test results["bindata"] == testdata
        end

        @testset "find_collections" begin
            for obj in Mongoc.find_collections(client["local"])
                @test obj["name"] == "startup_log"
            end

            @test Mongoc.get_collection_names(client["local"]) == [ "startup_log" ]
        end

        @testset "BulkOperation" begin
            coll = client[DB_NAME]["new_collection"]
            bulk_operation = Mongoc.BulkOperation(coll)
            Mongoc.destroy!(bulk_operation)
            bulk_2 = Mongoc.BulkOperation(coll) # will be freed by GC
        end


        @testset "insert_many" begin
            collection = client[DB_NAME]["insert_many"]
            vector = Vector{Mongoc.BSON}()
            push!(vector, Mongoc.BSON("""{ "hey" : "you" }"""))
            push!(vector, Mongoc.BSON("""{ "out" : "there" }"""))
            push!(vector, Mongoc.BSON("""{ "count" : 3 }"""))

            append!(collection, vector)
            @test length(collection) == 3
            @test length(collect(collection)) == 3

            empty!(collection)
            @test isempty(collection)
        end

        @testset "delete_one" begin
            collection = client[DB_NAME]["delete_one"]
            doc = Mongoc.BSON("""{ "to" : "delete", "hey" : "you" }""")
            doc2 = Mongoc.BSON("""{ "to" : "keep", "out" : "there" }""")
            insert_result = push!(collection, doc)
            oid = Mongoc.BSONObjectId(insert_result.inserted_oid)
            push!(collection, doc2)

            selector = Mongoc.BSON()
            selector["_id"] = oid
            @test length(collection, selector) == 1
            result = Mongoc.delete_one(collection, selector)
            @test result["deletedCount"] == 1
            @test length(collection, selector) == 0

            empty!(collection)
        end

        @testset "delete_many" begin
            collection = client[DB_NAME]["delete_many"]
            append!(collection, [ Mongoc.BSON("""{ "first" : 1, "delete" : true }"""), Mongoc.BSON("""{ "second" : 2, "delete" : true }"""), Mongoc.BSON("""{ "third" : 3, "delete" : false }""") ])
            @test length(collection) == 3
            result = Mongoc.delete_many(collection, Mongoc.BSON("""{ "delete" : true }"""))
            @test result["deletedCount"] == 2
            @test length(collection) == 1
            result = Mongoc.delete_many(collection, Mongoc.BSON())
            @test result["deletedCount"] == 1
            @test isempty(collection)
        end

        @testset "update_one, update_many" begin
            collection = client[DB_NAME]["update_one"]
            append!(collection, [ Mongoc.BSON("""{ "first" : 1, "delete" : true }"""), Mongoc.BSON("""{ "second" : 2, "delete" : true }"""), Mongoc.BSON("""{ "third" : 3, "delete" : false }""") ])
            @test length(collection) == 3

            selector = Mongoc.BSON("""{ "delete" : false }""")
            update = Mongoc.BSON("""{ "\$set" : { "delete" : true, "new_field" : 1 } }""")
            result = Mongoc.update_one(collection, selector, update)

            @test result["modifiedCount"] == 1
            @test result["matchedCount"] == 1
            @test result["upsertedCount"] == 0

            updated_bson = Mongoc.find_one(collection, Mongoc.BSON("""{ "third" : 3 }"""))
            @test updated_bson != nothing
            @test updated_bson["delete"] == true
            @test updated_bson["new_field"] == 1

            selector = Mongoc.BSON("""{ "delete" : true }""")
            update = Mongoc.BSON("""{ "\$set" : { "delete" : false } }""")
            result = Mongoc.update_many(collection, selector, update)
            @test result["modifiedCount"] == 3
            @test result["matchedCount"] == 3
            @test result["upsertedCount"] == 0

            for doc in Mongoc.find(collection)
                @test doc["delete"] == false
            end

            @test Mongoc.find_one(collection, Mongoc.BSON("""{ "delete" : true }""")) == nothing

            empty!(collection)
        end

        @testset "aggregation, map_reduce" begin
            # reproducing the examples at https://docs.mongodb.com/manual/aggregation/
            docs = [
                Mongoc.BSON("""{ "cust_id" : "A123", "amount" : 500, "status" : "A" }"""),
                Mongoc.BSON("""{ "cust_id" : "A123", "amount" : 250, "status" : "A" }"""),
                Mongoc.BSON("""{ "cust_id" : "B212", "amount" : 200, "status" : "A" }"""),
                Mongoc.BSON("""{ "cust_id" : "A123", "amount" : 300, "status" : "D" }""")
            ]

            database = client[DB_NAME]
            collection = database["aggregation_example"]
            append!(collection, docs)
            @test length(collection) == 4

            # Aggregation
            let
                bson_pipeline = Mongoc.BSON("""
                    [
                        { "\$match" : { "status" : "A" } },
                        { "\$group" : { "_id" : "\$cust_id", "total" : { "\$sum" : "\$amount" } } }
                    ]""")

                # Response should be
                #   BSON("{ "_id" : "B212", "total" : 200 }")
                #   BSON("{ "_id" : "A123", "total" : 750 }")
                for doc in Mongoc.aggregate(collection, bson_pipeline)
                    if doc["_id"] == "A123"
                        @test doc["total"] == 750
                    elseif doc["_id"] == "B212"
                        @test doc["total"] == 200
                    else
                        # shouldn't get in here
                        @test false
                    end
                end
            end

            # map_reduce
            let
                input_collection_name = "aggregation_example"
                mapper = Mongoc.BSONCode(""" function() { emit( this.cust_id, this.amount ); } """)
                reducer = Mongoc.BSONCode(""" function(key, values) { return Array.sum( values ) } """)
                output_collection_name = "order_totals"
                query = Mongoc.BSON("""{ "status" : "A" }""")

                map_reduce_command = Mongoc.BSON()
                map_reduce_command["mapReduce"] = input_collection_name
                map_reduce_command["map"] = mapper
                map_reduce_command["reduce"] = reducer
                map_reduce_command["out"] = output_collection_name
                map_reduce_command["query"] = query

                result = Mongoc.command_simple(database, map_reduce_command)
                @test result["result"] == "order_totals"
                @test result["ok"] == 1.0

                for doc in Mongoc.find(database["order_totals"])
                   if doc["_id"] == "A123"
                        @test doc["value"] == 750
                    elseif doc["_id"] == "B212"
                        @test doc["value"] == 200
                    else
                        # shouldn't get in here
                        @test false
                    end
                end

               # Response should be
               # BSON("{ "_id" : "A123", "value" : 750.0 }")
               # BSON("{ "_id" : "B212", "value" : 200.0 }")
            end

            empty!(collection)
        end
    end

    @testset "Users" begin
        # creates admin user - https://docs.mongodb.com/manual/tutorial/enable-authentication/
        @test Mongoc.has_database(client, DB_NAME) # at this point, DB_NAME should exist
        database = client[DB_NAME]

        user_name = "myUser"
        pass = "abc123"
        roles = Mongoc.BSON()

        if Mongoc.has_user(database, user_name)
            Mongoc.remove_user(database, user_name)
        end

        Mongoc.add_user(database, user_name, pass, roles)
        Mongoc.remove_user(database, user_name)
        @test !Mongoc.has_user(database, user_name)
    end

    @testset "Session Options" begin
        opt = Mongoc.SessionOptions()
        @test Mongoc.get_casual_consistency(opt)
        Mongoc.set_casual_consistency!(opt, false)
        @test !Mongoc.get_casual_consistency(opt)
    end

    server_version = Mongoc.get_server_mongodb_version(client)

    if server_version < v"3.6"
        @warn("MongoDB server version $server_version does not support Sessions. Skipping tests.")
    else
        @testset "Session" begin
            session = Mongoc.Session(client)
            db = session[DB_NAME]
            collection = db["session_collection"]
            push!(collection, Mongoc.BSON("""{ "try-insert" : 1 }"""))
            empty!(collection)
        end
    end
end
