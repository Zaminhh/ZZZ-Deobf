const { is, clone } = require("./helper")

const TRUE = { type: "BooleanLiteral", value: true }
const FALSE = { type: "BooleanLiteral", value: false }

const refCounts = (root) => {
    const counts = {}
    const bump = (name) => { counts[name] = (counts[name] || 0) + 1 }

    const walk = (node, isLocalDecl) => {
        if (!node || typeof node !== "object") return
        if (node.type === "Identifier") {
            bump(node.name)
        }
        for (const key in node) {
            const v = node[key]
            if (key === "type" || key === "raw" || key === "value" || key === "loc" || key === "range") continue
            if (Array.isArray(v)) { for (const item of v) walk(item, false) }
            else if (v && typeof v === "object") walk(v, false)
        }
    }

    walk(root)
    return counts
}

const removeStatementsByIndex = (body, indices) => {
    for (let i = indices.length - 1; i >= 0; i--)
        body.splice(indices[i], 1)
}

const cleanLocal = (stat) => {
    if (stat.type !== "LocalStatement") return false
    if (stat.variables.length !== 1) return false
    if (stat.init.length === 0) return false
    const name = stat.variables[0].name

    const init = stat.init[0]
    const isGetfenv = is(init, {
        type: "CallExpression",
        base: { type: "Identifier", name: "getfenv" },
        arguments: []
    })
    const isIdentity = is(init, { type: "Identifier" })
    const isEmptyTable = is(init, {
        type: "TableConstructorExpression",
        fields: []
    })

    if (isGetfenv)
        return { name, pristine: false }
    if (isEmptyTable)
        return { name, pristine: true }
    if (isIdentity && init.name !== name)
        return { name, pristine: true }

    return false
}

const collectBody = (body, state) => {
    if (!Array.isArray(body)) return
    for (let i = 0; i < body.length; i++) {
        const stat = body[i]
        if (!stat || !stat.type) continue

        if (stat.type === "IfStatement") {
            const clauses = stat.clauses || []
            for (let c = 0; c < clauses.length; c++) {
                collectBody(clauses[c].body, state)
            }
        } else if (stat.type === "DoStatement") {
            collectBody(stat.body, state)
        } else if (stat.type === "WhileStatement") {
            collectBody(stat.body, state)
        } else if (stat.type === "RepeatStatement") {
            collectBody(stat.body, state)
        } else if (stat.type === "ForGenericStatement") {
            collectBody(stat.body, state)
        } else if (stat.type === "ForNumericStatement") {
            collectBody(stat.body, state)
        } else if (stat.type === "FunctionDeclaration") {
            collectBody(stat.body, state)
        }

        const info = cleanLocal(stat)
        if (info) {
            state.locals.set(info.name, {
                pristine: info.pristine,
                useCount: 0
            })
        }
    }
}

const analyze = (body, state) => {
    if (!Array.isArray(body)) return
    for (const stat of body) {
        if (!stat || !stat.type) continue

        const localNames = new Set()
        const collectLocalNames = (node) => {
            if (!node || typeof node !== "object") return
            if (node.type === "LocalStatement") {
                for (const v of node.variables) localNames.add(v.name)
            }
            for (const key in node) {
                const v = node[key]
                if (key === "type" || key === "raw" || key === "loc" || key === "range") continue
                if (key === "localNames") continue
                if (Array.isArray(v)) { for (const item of v) collectLocalNames(item) }
                else if (v && typeof v === "object") collectLocalNames(v)
            }
        }

        const walkUses = (node, inAssignmentLhs) => {
            if (!node || typeof node !== "object") return
            if (node.type === "Identifier") {
                const info = state.locals.get(node.name)
                if (info && info.pristine && !localNames.has(node.name)) {
                    info.useCount++
                }
            }
            for (const key in node) {
                if (key === "type" || key === "raw" || key === "loc" || key === "range") continue
                const v = node[key]
                if (Array.isArray(v)) { for (const item of v) walkUses(item, false) }
                else if (v && typeof v === "object") walkUses(v, false)
            }
        }

        collectLocalNames(stat)
        walkUses(stat)
    }
}

const simplify = (body) => {
    const out = []
    for (const stat of body) {
        if (!stat || !stat.type) continue

        if (stat.type === "IfStatement") {
            const clauses = stat.clauses || []
            if (clauses.length === 1 && clauses[0].body) {
                const cond = clauses[0].condition
                if (cond && cond.type === "BooleanLiteral" && cond.value === true) {
                    out.push(...simplify(clauses[0].body))
                    continue
                }
                if (cond && cond.type === "BooleanLiteral" && cond.value === false) {
                    continue
                }
            }
        }

        if (stat.body && Array.isArray(stat.body)) {
            const cleaned = simplify(stat.body)
            stat.body = cleaned
        }
        if (stat.clauses && Array.isArray(stat.clauses)) {
            for (const clause of stat.clauses) {
                if (clause.body && Array.isArray(clause.body)) {
                    clause.body = simplify(clause.body)
                }
            }
        }

        out.push(stat)
    }
    return out
}

const clean = (ast) => {
    const root = { type: "Chunk", body: ast.body || [] }

    const state = { locals: new Map() }
    collectBody(root.body, state)
    analyze(root.body, state)

    const globalCount = {}
    const walkGlobal = (node) => {
        if (!node || typeof node !== "object") return
        if (node.type === "Identifier") {
            globalCount[node.name] = (globalCount[node.name] || 0) + 1
        }
        for (const key in node) {
            const v = node[key]
            if (key === "type" || key === "raw" || key === "loc" || key === "range") continue
            if (Array.isArray(v)) { for (const item of v) walkGlobal(item) }
            else if (v && typeof v === "object") walkGlobal(v)
        }
    }
    walkGlobal(root)

    const removePrune = (body) => {
        if (!Array.isArray(body)) return
        for (let i = 0; i < body.length; i++) {
            const stat = body[i]
            if (!stat || !stat.type) continue
            if (stat.type === "LocalStatement" && stat.variables.length === 1) {
                const name = stat.variables[0].name
                const info = state.locals.get(name)
                const isGetfenv = is(stat.init[0], {
                    type: "CallExpression",
                    base: { type: "Identifier", name: "getfenv" },
                    arguments: []
                })
                const safeWithoutUse = info && info.useCount === 0 &&
                    (info.pristine || isGetfenv)
                if (safeWithoutUse) {
                    body.splice(i, 1)
                    i--
                    continue
                }
            }
            if (stat.type === "AssignmentStatement") {
                let orphan = stat.variables.length === 1 &&
                    stat.variables[0].type === "Identifier"
                if (orphan) {
                    const name = stat.variables[0].name
                    orphan = (globalCount[name] || 0) === 1
                }
                if (orphan) {
                    body.splice(i, 1)
                    i--
                    continue
                }
            }
            if (stat.body && Array.isArray(stat.body)) removePrune(stat.body)
            if (stat.clauses && Array.isArray(stat.clauses))
                for (const clause of stat.clauses) if (clause.body) removePrune(clause.body)
        }
    }

    removePrune(root.body)

    const finalBody = simplify(root.body)

    return { type: "Chunk", body: finalBody }
}

module.exports = clean
