local flags = require("./flags")
local guid = require("./guid")
local flags = require("./flags")
local types = require("./types")
local Session = require("./session")
local budget = require("./budget")
local LOG = require("./log")
local task = require("./task")
local actions = require("./actions")
local checktransaction = require("./checktransaction")

local TRANSACTION_NAME = "_$SKILIFT_TRANSACTION"
local TRANSACTION_SCOPE = "global"

type TransactionInfo = types.TransactionInfo
type TransactionId = types.TransactionId

local function create_transaction(success: (() -> ()), failure: (() -> ())?)
    local TRANSACTION_STORE = flags.datastoreservice:GetDataStore(TRANSACTION_NAME, TRANSACTION_SCOPE)
    
    local uuid = guid()
    LOG(`STARTING TRANSACTION ID {uuid}`)
    local transaction_info: TransactionInfo = {
        uuid = uuid,
        state = "success",
        sessions = {}
    }

    LOG("GETTING ACTIONS FOR SUCCESS")
    do
        transaction_info.state = "success"
        flags.processing_transaction = transaction_info
        local thread = coroutine.create(success)
        local ok, err = coroutine.resume(thread)
        flags.processing_transaction = false

        if not ok then error(err) end
    end
    LOG("GETTING ACTIONS FOR FAILURE")

    if failure then
        transaction_info.state = "failure"
        flags.processing_transaction = transaction_info
        local thread = coroutine.create(failure)
        local ok, err = coroutine.resume(thread)
        flags.processing_transaction = false

        if not ok then error(err) end
    end

    local total = 0

    for _ in transaction_info.sessions do
        total += 1
    end

    if total == 0 then return true end

    LOG(`{uuid}: WAITING FOR {total + 6} UPDATE BUDGET FOR {total} SESSIONS, CURRENT: {budget.get_budget("update")}`)
    budget.delay_until_meets_budget("update", total + 6)

    -- each session needs to be manually pulled
    local success, failed = 0, 0
    for session, info in transaction_info.sessions do
        LOG(`{uuid}: Pulling {session._name}`)
        task.spawn(function()
            local ok = pcall(Session.pull_auto, session, { [uuid] = info })
            LOG(`{uuid}: STATUS {if ok then "SUCCESS" else "FAIL"}`)
            if ok == false then
                failed += 1
            end
            if ok == true then success += 1 end
        end) 
    end
    
    while success < total and failed == 0 do
        task.wait() -- yield until all threads finished
    end
    LOG(`{uuid}: TOTAL {total}, SUCCESS {success}, FAIL {failed}`)

    if success == total then
        -- everything has been saved, we can now mark the transaction as finished
        local ok, err = pcall(function()
            budget.delay_until_meets_budget("set", 1)
            TRANSACTION_STORE:SetAsync(uuid, "finished")
        end)
        LOG(`{uuid}: WRITTEN TO KEY STATUS {if ok then "SUCCESS" else "FAIL"}`)
        
        checktransaction.set_transaction_status(uuid, ok)

        for session, info in transaction_info.sessions do
            LOG(`{uuid}: Pulling {session._name}`)
            for _, action in (if ok == true then info.success else info.failure) do
                local fn = actions.obtain_transaction_action(session._.store, action.fn)
                Session.commit_transaction_early(session, fn, unpack(action.values))
            end
        end
        
        return ok
    else
        checktransaction.set_transaction_status(uuid, false)
        -- now that the transaction is done, we can pull all data again
        for session, info in transaction_info.sessions do
            LOG(`{uuid}: Pulling {session._name}`)
            for _, action in info.failure do
                local fn = actions.obtain_transaction_action(session._.store, action.fn)
                Session.commit_transaction_early(session, fn, unpack(action.values))
            end
        end

        return false
    end 
end

return {
    create_transaction = create_transaction

}