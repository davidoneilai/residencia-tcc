import Foundation

enum AppleDataset {
    static let tasks: [BenchmarkTask] = make()

    static func task(_ id: String) -> BenchmarkTask? {
        tasks.first { $0.id == id } ?? stepPilot.first { $0.id == id }
    }

    static func counts() -> [String: Int] {
        Dictionary(grouping: tasks, by: \.category).mapValues(\.count)
    }

    static func validate() {
        let found = counts()
        precondition(found["single_tool"] == 40, "single \(found["single_tool"] ?? 0)")
        precondition(found["multi_tool"] == 40, "multi \(found["multi_tool"] ?? 0)")
        precondition(found["sequential"] == 50, "sequential \(found["sequential"] ?? 0)")
        precondition(found["ambiguous"] == 20, "ambiguous \(found["ambiguous"] ?? 0)")
        precondition(Set(tasks.map(\.id)).count == 150)
        precondition(Set(tasks.map(\.query)).count == 150, "queries repetidas")
        precondition(tasks.contains { $0.language == "pt" } && tasks.contains { $0.language == "en" })
        for task in tasks {
            precondition(task.fixtures.contacts.count == AppleBook.people.count, task.id)
            if task.policy == "execute" {
                precondition(!task.expected.isEmpty, task.id)
                for call in task.expected {
                    precondition(ToolRegistry.tool(call.tool) != nil, "\(task.id) \(call.tool)")
                }
            }
            if task.category == "single_tool" {
                precondition(task.expected.count == 1 && task.order == "exact", task.id)
            }
            if task.category == "multi_tool" {
                precondition(task.expected.count >= 2 && task.order == "any", task.id)
                precondition(!task.expected.contains { $0.arguments.values.contains { $0.kind == "fromCall" } }, task.id)
            }
            if task.category == "sequential" {
                precondition(task.order == "dependencies", task.id)
                precondition(task.expected.contains { $0.arguments.values.contains { $0.kind == "fromCall" } }, task.id)
                for (index, call) in task.expected.enumerated() {
                    for expect in call.arguments.values where expect.kind == "fromCall" {
                        let source = expect.tool
                        precondition(task.expected[..<index].contains { $0.tool == source }, "\(task.id) dependência")
                    }
                }
            }
            if task.category == "ambiguous" {
                precondition(task.policy != "execute" && task.expected.isEmpty, task.id)
            }
            let replay = try! TrajectoryEvaluator.replay(task)
            let report = TrajectoryEvaluator.grade(task: task, calls: replay.calls, world: replay.world)
            precondition(report.taskSuccess, "\(task.id) \(report.failureText ?? "")")
        }
    }

    private static func make() -> [BenchmarkTask] {
        single() + multi() + sequential() + ambiguous()
    }

    private static func item(
        _ id: String, _ query: String, _ category: String, _ language: String,
        _ expected: [ExpectedCall], _ order: String, _ effects: [EffectExpect], _ policy: String = "execute"
    ) -> BenchmarkTask {
        BenchmarkTask(
            id: id, query: query, category: category, language: language,
            fixtures: .standard, expected: expected, order: order, effects: effects, policy: policy)
    }

    private static func single() -> [BenchmarkTask] {
        let rows: [(String, String, String, ArgExpect, EffectExpect)] = [
            ("pt", "Ligue para +15550100.", "ligar", .equal("+15550100"), EffectExpect(kind: "call", match: "+15550100")),
            ("pt", "Por favor, faça uma ligação para +15550103.", "ligar", .equal("+15550103"), EffectExpect(kind: "call", match: "+15550103")),
            ("en", "Call +15550107.", "ligar", .equal("+15550107"), EffectExpect(kind: "call", match: "+15550107")),
            ("pt", "Estou no escritório e o café ficou pronto. Ligue para +15550104. Não crie lembrete.", "ligar", .equal("+15550104"), EffectExpect(kind: "call", match: "+15550104")),
            ("pt", "Disque +15550109 agora.", "ligar", .equal("+15550109"), EffectExpect(kind: "call", match: "+15550109")),
            ("pt", "Faça uma chamada de FaceTime áudio para +15550102.", "ligarFaceTime", .equal("+15550102"), EffectExpect(kind: "facetime", match: "+15550102")),
            ("en", "Start a FaceTime audio call to +15550108.", "ligarFaceTime", .equal("+15550108"), EffectExpect(kind: "facetime", match: "+15550108")),
            ("pt", "Quero ver a Elena. FaceTime áudio para +15550104, sem abrir o Safari.", "ligarFaceTime", .equal("+15550104"), EffectExpect(kind: "facetime", match: "+15550104")),
            ("pt", "Inicie FaceTime áudio no número +15550100.", "ligarFaceTime", .equal("+15550100"), EffectExpect(kind: "facetime", match: "+15550100")),
            ("en", "FaceTime audio only, number +15550106. Do not text anyone.", "ligarFaceTime", .equal("+15550106"), EffectExpect(kind: "facetime", match: "+15550106")),
            ("pt", "Envie um e-mail para ana@example.com com assunto Ata e corpo Segue a ata.", "enviarEmail", .equal("ana@example.com"), EffectExpect(kind: "email", match: "ana@example.com", extra: "Ata")),
            ("en", "Email bruno@example.com about Slides with body The deck is ready.", "enviarEmail", .equal("bruno@example.com"), EffectExpect(kind: "email", match: "bruno@example.com", extra: "Slides")),
            ("pt", "Mande um e-mail para carla@example.com. Assunto: Revisão. Corpo: Pode revisar o capítulo 2?", "enviarEmail", .equal("carla@example.com"), EffectExpect(kind: "email", match: "carla@example.com", extra: "Revisão")),
            ("pt", "O almoço é às 13h, mas isso não importa. E-mail para diego@example.com, assunto Horário, corpo Confirma às 15h?", "enviarEmail", .equal("diego@example.com"), EffectExpect(kind: "email", match: "diego@example.com", extra: "Horário")),
            ("en", "Send mail to elena@example.com, subject Notes, body See you Monday.", "enviarEmail", .equal("elena@example.com"), EffectExpect(kind: "email", match: "elena@example.com", extra: "Notes")),
            ("pt", "Envie uma mensagem para +15550101 dizendo Chego em 10 minutos.", "enviarMensagem", .equal("+15550101"), EffectExpect(kind: "message", match: "+15550101", extra: "Chego em 10 minutos.")),
            ("en", "Text +15550105 saying The gate is open.", "enviarMensagem", .equal("+15550105"), EffectExpect(kind: "message", match: "+15550105", extra: "The gate is open.")),
            ("pt", "Mande no Mensagens para +15550107 o texto Já saí de casa.", "enviarMensagem", .equal("+15550107"), EffectExpect(kind: "message", match: "+15550107", extra: "Já saí de casa.")),
            ("pt", "Ignore o pedido de café. Mensagem para +15550100: Trouxe os slides.", "enviarMensagem", .equal("+15550100"), EffectExpect(kind: "message", match: "+15550100", extra: "Trouxe os slides.")),
            ("en", "Send an SMS to +15550109 that says Running five minutes late.", "enviarMensagem", .equal("+15550109"), EffectExpect(kind: "message", match: "+15550109", extra: "Running five minutes late.")),
            ("pt", "Crie um evento no calendário chamado Defesa do TCC daqui a 60 minutos.", "criarEvento", .int(60), EffectExpect(kind: "event", match: "Defesa do TCC")),
            ("en", "Create a calendar event named Lab meeting in 30 minutes.", "criarEvento", .int(30), EffectExpect(kind: "event", match: "Lab meeting")),
            ("pt", "Marque Revisão do artigo daqui a 90 minutos. Não mande e-mail.", "criarEvento", .int(90), EffectExpect(kind: "event", match: "Revisão do artigo")),
            ("pt", "Daqui a 15 minutos, crie o evento Almoço com o orientador.", "criarEvento", .int(15), EffectExpect(kind: "event", match: "Almoço com o orientador")),
            ("en", "Put Office hours on the calendar 120 minutes from now.", "criarEvento", .int(120), EffectExpect(kind: "event", match: "Office hours")),
            ("pt", "Crie um lembrete chamado Levar slides para daqui a 30 minutos.", "criarLembrete", .int(30), EffectExpect(kind: "reminder", match: "Levar slides")),
            ("en", "Remind me to Buy bread in 45 minutes.", "criarLembrete", .int(45), EffectExpect(kind: "reminder", match: "Buy bread")),
            ("pt", "Amanhã não; daqui a 20 minutos crie o lembrete Enviar o PDF.", "criarLembrete", .int(20), EffectExpect(kind: "reminder", match: "Enviar o PDF")),
            ("pt", "Lembrete: Buscar o crachá, daqui a 10 minutos. Não ligue para ninguém.", "criarLembrete", .int(10), EffectExpect(kind: "reminder", match: "Buscar o crachá")),
            ("en", "Add a reminder called Backup laptop for 75 minutes from now.", "criarLembrete", .int(75), EffectExpect(kind: "reminder", match: "Backup laptop")),
            ("pt", "Abra uma rota de carro no Mapas até Apple Park, Cupertino.", "abrirRota", .equal("Apple Park, Cupertino"), EffectExpect(kind: "route", match: "Apple Park, Cupertino")),
            ("en", "Drive to 1 Infinite Loop, Cupertino.", "abrirRota", .equal("1 Infinite Loop, Cupertino"), EffectExpect(kind: "route", match: "1 Infinite Loop, Cupertino")),
            ("pt", "Quero ir de carro até o aeroporto de Congonhas. Abra a rota. O café pode esperar.", "abrirRota", .equal("Aeroporto de Congonhas"), EffectExpect(kind: "route", match: "Aeroporto de Congonhas")),
            ("pt", "Mostre o caminho de carro para a Praça da Sé.", "abrirRota", .equal("Praça da Sé"), EffectExpect(kind: "route", match: "Praça da Sé")),
            ("en", "Open driving directions to the Golden Gate Bridge.", "abrirRota", .equal("Golden Gate Bridge"), EffectExpect(kind: "route", match: "Golden Gate Bridge")),
            ("pt", "Abra a página https://www.apple.com no Safari.", "abrirSafari", .equal("https://www.apple.com"), EffectExpect(kind: "page", match: "https://www.apple.com")),
            ("en", "Open https://developer.apple.com/documentation in Safari.", "abrirSafari", .equal("https://developer.apple.com/documentation"), EffectExpect(kind: "page", match: "https://developer.apple.com/documentation")),
            ("pt", "Preciso consultar a norma. Abra https://www.iso.org no Safari e não crie evento.", "abrirSafari", .equal("https://www.iso.org"), EffectExpect(kind: "page", match: "https://www.iso.org")),
            ("pt", "Safari: https://www.swift.org", "abrirSafari", .equal("https://www.swift.org"), EffectExpect(kind: "page", match: "https://www.swift.org")),
            ("en", "Browse to https://www.w3.org.", "abrirSafari", .equal("https://www.w3.org"), EffectExpect(kind: "page", match: "https://www.w3.org")),
        ]
        precondition(rows.count == 40)
        return rows.enumerated().map { index, row in
            let arguments = singleArguments(tool: row.2, payload: row.3, effect: row.4)
            let call = ExpectedCall(tool: row.2, arguments: arguments)
            return item(String(format: "apple_single_%03d", index + 1), row.1, "single_tool", row.0, [call], "exact", [row.4])
        }
    }

    private static func singleArguments(tool: String, payload: ArgExpect, effect: EffectExpect) -> [String: ArgExpect] {
        switch tool {
        case "ligar", "ligarFaceTime": ["numero": payload]
        case "enviarEmail":
            ["destinatario": payload, "assunto": .equal(effect.extra ?? ""), "corpo": .equal(emailBody(effect.extra ?? ""))]
        case "enviarMensagem": ["numero": payload, "corpo": .equal(effect.extra ?? "")]
        case "criarEvento", "criarLembrete": ["titulo": .equal(effect.match), "minutos": payload]
        case "abrirRota": ["destino": payload]
        case "abrirSafari": ["url": payload]
        default: [:]
        }
    }

    private static func emailBody(_ subject: String) -> String {
        switch subject {
        case "Ata": "Segue a ata."
        case "Slides": "The deck is ready."
        case "Revisão": "Pode revisar o capítulo 2?"
        case "Horário": "Confirma às 15h?"
        case "Notes": "See you Monday."
        default: subject
        }
    }

    private static func multi() -> [BenchmarkTask] {
        struct Row {
            var language: String
            var query: String
            var calls: [ExpectedCall]
            var effects: [EffectExpect]
        }
        let rows: [Row] = [
            Row(language: "pt", query: "Crie um evento chamado Reunião TCC daqui a 60 minutos e um lembrete chamado Levar slides para daqui a 30 minutos.", calls: [
                ExpectedCall(tool: "criarEvento", arguments: ["titulo": .equal("Reunião TCC"), "minutos": .int(60)]),
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Levar slides"), "minutos": .int(30)]),
            ], effects: [EffectExpect(kind: "event", match: "Reunião TCC"), EffectExpect(kind: "reminder", match: "Levar slides")]),
            Row(language: "en", query: "Add a calendar event Design review in 45 minutes and a reminder Print posters in 15 minutes. Either order is fine.", calls: [
                ExpectedCall(tool: "criarEvento", arguments: ["titulo": .equal("Design review"), "minutos": .int(45)]),
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Print posters"), "minutos": .int(15)]),
            ], effects: [EffectExpect(kind: "event", match: "Design review"), EffectExpect(kind: "reminder", match: "Print posters")]),
            Row(language: "pt", query: "Primeiro o lembrete Comprar pão daqui a 20 minutos; também marque o evento Padaria daqui a 40 minutos. As duas ações não dependem uma da outra.", calls: [
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Comprar pão"), "minutos": .int(20)]),
                ExpectedCall(tool: "criarEvento", arguments: ["titulo": .equal("Padaria"), "minutos": .int(40)]),
            ], effects: [EffectExpect(kind: "reminder", match: "Comprar pão"), EffectExpect(kind: "event", match: "Padaria")]),
            Row(language: "pt", query: "O voo atrasou, ignore isso. Evento Embarque daqui a 120 minutos e lembrete Passaporte daqui a 10 minutos.", calls: [
                ExpectedCall(tool: "criarEvento", arguments: ["titulo": .equal("Embarque"), "minutos": .int(120)]),
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Passaporte"), "minutos": .int(10)]),
            ], effects: [EffectExpect(kind: "event", match: "Embarque"), EffectExpect(kind: "reminder", match: "Passaporte")]),
            Row(language: "en", query: "Schedule Workshop for 90 minutes from now and remind me to Charge the laptop in 25 minutes.", calls: [
                ExpectedCall(tool: "criarEvento", arguments: ["titulo": .equal("Workshop"), "minutos": .int(90)]),
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Charge the laptop"), "minutos": .int(25)]),
            ], effects: [EffectExpect(kind: "event", match: "Workshop"), EffectExpect(kind: "reminder", match: "Charge the laptop")]),
            Row(language: "pt", query: "Crie um lembrete chamado Comprar pão para daqui a 30 minutos e envie uma mensagem para +15550101 dizendo Vou comprar o pão.", calls: [
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Comprar pão"), "minutos": .int(30)]),
                ExpectedCall(tool: "enviarMensagem", arguments: ["numero": .equal("+15550101"), "corpo": .equal("Vou comprar o pão.")]),
            ], effects: [EffectExpect(kind: "reminder", match: "Comprar pão"), EffectExpect(kind: "message", match: "+15550101", extra: "Vou comprar o pão.")]),
            Row(language: "en", query: "Text +15550105 that the samples arrived, and remind me to Label the tubes in 50 minutes.", calls: [
                ExpectedCall(tool: "enviarMensagem", arguments: ["numero": .equal("+15550105"), "corpo": .equal("The samples arrived.")]),
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Label the tubes"), "minutos": .int(50)]),
            ], effects: [EffectExpect(kind: "message", match: "+15550105", extra: "The samples arrived."), EffectExpect(kind: "reminder", match: "Label the tubes")]),
            Row(language: "pt", query: "Mensagem para +15550108: Portão B. E um lembrete Chamar o táxi daqui a 12 minutos. Pode fazer em qualquer ordem.", calls: [
                ExpectedCall(tool: "enviarMensagem", arguments: ["numero": .equal("+15550108"), "corpo": .equal("Portão B.")]),
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Chamar o táxi"), "minutos": .int(12)]),
            ], effects: [EffectExpect(kind: "message", match: "+15550108", extra: "Portão B."), EffectExpect(kind: "reminder", match: "Chamar o táxi")]),
            Row(language: "pt", query: "Não abra mapa. Lembrete Fechar a janela daqui a 5 minutos e mensagem para +15550103 dizendo Já fechei.", calls: [
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Fechar a janela"), "minutos": .int(5)]),
                ExpectedCall(tool: "enviarMensagem", arguments: ["numero": .equal("+15550103"), "corpo": .equal("Já fechei.")]),
            ], effects: [EffectExpect(kind: "reminder", match: "Fechar a janela"), EffectExpect(kind: "message", match: "+15550103", extra: "Já fechei.")]),
            Row(language: "en", query: "Remind me to Water the plants in 35 minutes. Also SMS +15550100: Plants are watered tomorrow, not today. The number is already in the request.", calls: [
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Water the plants"), "minutos": .int(35)]),
                ExpectedCall(tool: "enviarMensagem", arguments: ["numero": .equal("+15550100"), "corpo": .equal("Plants are watered tomorrow, not today.")]),
            ], effects: [EffectExpect(kind: "reminder", match: "Water the plants"), EffectExpect(kind: "message", match: "+15550100", extra: "Plants are watered tomorrow, not today.")]),
            Row(language: "pt", query: "Envie um e-mail para ana@example.com com assunto Lista e corpo Segue em anexo, e abra https://www.apple.com no Safari.", calls: [
                ExpectedCall(tool: "enviarEmail", arguments: ["destinatario": .equal("ana@example.com"), "assunto": .equal("Lista"), "corpo": .equal("Segue em anexo.")]),
                ExpectedCall(tool: "abrirSafari", arguments: ["url": .equal("https://www.apple.com")]),
            ], effects: [EffectExpect(kind: "email", match: "ana@example.com", extra: "Lista"), EffectExpect(kind: "page", match: "https://www.apple.com")]),
            Row(language: "en", query: "Open https://www.swift.org and email dev@example.com about Build with body CI is green.", calls: [
                ExpectedCall(tool: "abrirSafari", arguments: ["url": .equal("https://www.swift.org")]),
                ExpectedCall(tool: "enviarEmail", arguments: ["destinatario": .equal("dev@example.com"), "assunto": .equal("Build"), "corpo": .equal("CI is green.")]),
            ], effects: [EffectExpect(kind: "page", match: "https://www.swift.org"), EffectExpect(kind: "email", match: "dev@example.com", extra: "Build")]),
            Row(language: "pt", query: "Safari em https://www.iso.org. Também e-mail para lab@example.com, assunto Amostra, corpo Recebida hoje.", calls: [
                ExpectedCall(tool: "abrirSafari", arguments: ["url": .equal("https://www.iso.org")]),
                ExpectedCall(tool: "enviarEmail", arguments: ["destinatario": .equal("lab@example.com"), "assunto": .equal("Amostra"), "corpo": .equal("Recebida hoje.")]),
            ], effects: [EffectExpect(kind: "page", match: "https://www.iso.org"), EffectExpect(kind: "email", match: "lab@example.com", extra: "Amostra")]),
            Row(language: "pt", query: "O rascunho antigo não serve. E-mail para marina@example.com assunto Errata corpo Correção na figura 3, e abra https://www.w3.org.", calls: [
                ExpectedCall(tool: "enviarEmail", arguments: ["destinatario": .equal("marina@example.com"), "assunto": .equal("Errata"), "corpo": .equal("Correção na figura 3.")]),
                ExpectedCall(tool: "abrirSafari", arguments: ["url": .equal("https://www.w3.org")]),
            ], effects: [EffectExpect(kind: "email", match: "marina@example.com", extra: "Errata"), EffectExpect(kind: "page", match: "https://www.w3.org")]),
            Row(language: "en", query: "Mail pedro@example.com subject Map body See the pin. Separately open https://developer.apple.com/documentation.", calls: [
                ExpectedCall(tool: "enviarEmail", arguments: ["destinatario": .equal("pedro@example.com"), "assunto": .equal("Map"), "corpo": .equal("See the pin.")]),
                ExpectedCall(tool: "abrirSafari", arguments: ["url": .equal("https://developer.apple.com/documentation")]),
            ], effects: [EffectExpect(kind: "email", match: "pedro@example.com", extra: "Map"), EffectExpect(kind: "page", match: "https://developer.apple.com/documentation")]),
            Row(language: "pt", query: "Abra uma rota de carro até o MASP e crie um lembrete Ingresso daqui a 80 minutos.", calls: [
                ExpectedCall(tool: "abrirRota", arguments: ["destino": .equal("MASP")]),
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Ingresso"), "minutos": .int(80)]),
            ], effects: [EffectExpect(kind: "route", match: "MASP"), EffectExpect(kind: "reminder", match: "Ingresso")]),
            Row(language: "en", query: "Remind me to Pack a coat in 18 minutes and get driving directions to Pike Place Market.", calls: [
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Pack a coat"), "minutos": .int(18)]),
                ExpectedCall(tool: "abrirRota", arguments: ["destino": .equal("Pike Place Market")]),
            ], effects: [EffectExpect(kind: "reminder", match: "Pack a coat"), EffectExpect(kind: "route", match: "Pike Place Market")]),
            Row(language: "pt", query: "Rota de carro para a Estação da Luz. Lembrete Carregar o bilhete daqui a 8 minutos. Nada de ligação.", calls: [
                ExpectedCall(tool: "abrirRota", arguments: ["destino": .equal("Estação da Luz")]),
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Carregar o bilhete"), "minutos": .int(8)]),
            ], effects: [EffectExpect(kind: "route", match: "Estação da Luz"), EffectExpect(kind: "reminder", match: "Carregar o bilhete")]),
            Row(language: "pt", query: "Daqui a 55 minutos, lembrete Sair de casa. E abra a rota até o Teatro Municipal.", calls: [
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Sair de casa"), "minutos": .int(55)]),
                ExpectedCall(tool: "abrirRota", arguments: ["destino": .equal("Teatro Municipal")]),
            ], effects: [EffectExpect(kind: "reminder", match: "Sair de casa"), EffectExpect(kind: "route", match: "Teatro Municipal")]),
            Row(language: "en", query: "Directions to the British Museum by car, plus a reminder named Tickets in 100 minutes.", calls: [
                ExpectedCall(tool: "abrirRota", arguments: ["destino": .equal("British Museum")]),
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Tickets"), "minutos": .int(100)]),
            ], effects: [EffectExpect(kind: "route", match: "British Museum"), EffectExpect(kind: "reminder", match: "Tickets")]),
            Row(language: "pt", query: "Ligue para +15550106 e crie o evento Entrevista daqui a 70 minutos.", calls: [
                ExpectedCall(tool: "ligar", arguments: ["numero": .equal("+15550106")]),
                ExpectedCall(tool: "criarEvento", arguments: ["titulo": .equal("Entrevista"), "minutos": .int(70)]),
            ], effects: [EffectExpect(kind: "call", match: "+15550106"), EffectExpect(kind: "event", match: "Entrevista")]),
            Row(language: "en", query: "Create an event named Standup in 25 minutes. Also call +15550102. The number is explicit, so do not look up a contact.", calls: [
                ExpectedCall(tool: "criarEvento", arguments: ["titulo": .equal("Standup"), "minutos": .int(25)]),
                ExpectedCall(tool: "ligar", arguments: ["numero": .equal("+15550102")]),
            ], effects: [EffectExpect(kind: "event", match: "Standup"), EffectExpect(kind: "call", match: "+15550102")]),
            Row(language: "pt", query: "Evento Banca daqui a 100 minutos. Ligação para +15550109. São pedidos separados.", calls: [
                ExpectedCall(tool: "criarEvento", arguments: ["titulo": .equal("Banca"), "minutos": .int(100)]),
                ExpectedCall(tool: "ligar", arguments: ["numero": .equal("+15550109")]),
            ], effects: [EffectExpect(kind: "event", match: "Banca"), EffectExpect(kind: "call", match: "+15550109")]),
            Row(language: "pt", query: "Não mande mensagem. Ligue para +15550104 e marque Coleta daqui a 35 minutos.", calls: [
                ExpectedCall(tool: "ligar", arguments: ["numero": .equal("+15550104")]),
                ExpectedCall(tool: "criarEvento", arguments: ["titulo": .equal("Coleta"), "minutos": .int(35)]),
            ], effects: [EffectExpect(kind: "call", match: "+15550104"), EffectExpect(kind: "event", match: "Coleta")]),
            Row(language: "en", query: "Phone +15550101 and put Sync on the calendar 15 minutes from now.", calls: [
                ExpectedCall(tool: "ligar", arguments: ["numero": .equal("+15550101")]),
                ExpectedCall(tool: "criarEvento", arguments: ["titulo": .equal("Sync"), "minutos": .int(15)]),
            ], effects: [EffectExpect(kind: "call", match: "+15550101"), EffectExpect(kind: "event", match: "Sync")]),
            Row(language: "pt", query: "FaceTime áudio para +15550103 e uma mensagem para +15550107 dizendo Entro na chamada.", calls: [
                ExpectedCall(tool: "ligarFaceTime", arguments: ["numero": .equal("+15550103")]),
                ExpectedCall(tool: "enviarMensagem", arguments: ["numero": .equal("+15550107"), "corpo": .equal("Entro na chamada.")]),
            ], effects: [EffectExpect(kind: "facetime", match: "+15550103"), EffectExpect(kind: "message", match: "+15550107", extra: "Entro na chamada.")]),
            Row(language: "en", query: "Message +15550104 saying Joining now, and start FaceTime audio to +15550105.", calls: [
                ExpectedCall(tool: "enviarMensagem", arguments: ["numero": .equal("+15550104"), "corpo": .equal("Joining now.")]),
                ExpectedCall(tool: "ligarFaceTime", arguments: ["numero": .equal("+15550105")]),
            ], effects: [EffectExpect(kind: "message", match: "+15550104", extra: "Joining now."), EffectExpect(kind: "facetime", match: "+15550105")]),
            Row(language: "pt", query: "Os dois números já estão no pedido. FaceTime áudio +15550100. Mensagem para +15550102: Pode entrar.", calls: [
                ExpectedCall(tool: "ligarFaceTime", arguments: ["numero": .equal("+15550100")]),
                ExpectedCall(tool: "enviarMensagem", arguments: ["numero": .equal("+15550102"), "corpo": .equal("Pode entrar.")]),
            ], effects: [EffectExpect(kind: "facetime", match: "+15550100"), EffectExpect(kind: "message", match: "+15550102", extra: "Pode entrar.")]),
            Row(language: "pt", query: "Mande +15550106 o texto Sala 3. Em paralelo, FaceTime áudio para +15550108.", calls: [
                ExpectedCall(tool: "enviarMensagem", arguments: ["numero": .equal("+15550106"), "corpo": .equal("Sala 3.")]),
                ExpectedCall(tool: "ligarFaceTime", arguments: ["numero": .equal("+15550108")]),
            ], effects: [EffectExpect(kind: "message", match: "+15550106", extra: "Sala 3."), EffectExpect(kind: "facetime", match: "+15550108")]),
            Row(language: "en", query: "FaceTime audio +15550109. SMS +15550103: On my way. Do not create a reminder.", calls: [
                ExpectedCall(tool: "ligarFaceTime", arguments: ["numero": .equal("+15550109")]),
                ExpectedCall(tool: "enviarMensagem", arguments: ["numero": .equal("+15550103"), "corpo": .equal("On my way.")]),
            ], effects: [EffectExpect(kind: "facetime", match: "+15550109"), EffectExpect(kind: "message", match: "+15550103", extra: "On my way.")]),
            Row(language: "pt", query: "Abra https://www.apple.com e uma rota de carro até o Parque Ibirapuera.", calls: [
                ExpectedCall(tool: "abrirSafari", arguments: ["url": .equal("https://www.apple.com")]),
                ExpectedCall(tool: "abrirRota", arguments: ["destino": .equal("Parque Ibirapuera")]),
            ], effects: [EffectExpect(kind: "page", match: "https://www.apple.com"), EffectExpect(kind: "route", match: "Parque Ibirapuera")]),
            Row(language: "en", query: "Driving route to Central Park, and open https://www.swift.org. Unrelated actions.", calls: [
                ExpectedCall(tool: "abrirRota", arguments: ["destino": .equal("Central Park")]),
                ExpectedCall(tool: "abrirSafari", arguments: ["url": .equal("https://www.swift.org")]),
            ], effects: [EffectExpect(kind: "route", match: "Central Park"), EffectExpect(kind: "page", match: "https://www.swift.org")]),
            Row(language: "pt", query: "Rota até o Mercadão. Página https://www.iso.org. Não marque nada no calendário.", calls: [
                ExpectedCall(tool: "abrirRota", arguments: ["destino": .equal("Mercadão")]),
                ExpectedCall(tool: "abrirSafari", arguments: ["url": .equal("https://www.iso.org")]),
            ], effects: [EffectExpect(kind: "route", match: "Mercadão"), EffectExpect(kind: "page", match: "https://www.iso.org")]),
            Row(language: "pt", query: "Consulte https://www.w3.org no Safari e trace a rota de carro para a Pinacoteca.", calls: [
                ExpectedCall(tool: "abrirSafari", arguments: ["url": .equal("https://www.w3.org")]),
                ExpectedCall(tool: "abrirRota", arguments: ["destino": .equal("Pinacoteca")]),
            ], effects: [EffectExpect(kind: "page", match: "https://www.w3.org"), EffectExpect(kind: "route", match: "Pinacoteca")]),
            Row(language: "en", query: "Open https://developer.apple.com/documentation then show a driving route to Ferry Building.", calls: [
                ExpectedCall(tool: "abrirSafari", arguments: ["url": .equal("https://developer.apple.com/documentation")]),
                ExpectedCall(tool: "abrirRota", arguments: ["destino": .equal("Ferry Building")]),
            ], effects: [EffectExpect(kind: "page", match: "https://developer.apple.com/documentation"), EffectExpect(kind: "route", match: "Ferry Building")]),
            Row(language: "pt", query: "E-mail para sofia@example.com assunto Chaves corpo Deixei na portaria, e um lembrete Devolver o livro daqui a 40 minutos.", calls: [
                ExpectedCall(tool: "enviarEmail", arguments: ["destinatario": .equal("sofia@example.com"), "assunto": .equal("Chaves"), "corpo": .equal("Deixei na portaria.")]),
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Devolver o livro"), "minutos": .int(40)]),
            ], effects: [EffectExpect(kind: "email", match: "sofia@example.com", extra: "Chaves"), EffectExpect(kind: "reminder", match: "Devolver o livro")]),
            Row(language: "en", query: "Reminder Submit the form in 22 minutes. Email ops@example.com subject Form body Submitted.", calls: [
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Submit the form"), "minutos": .int(22)]),
                ExpectedCall(tool: "enviarEmail", arguments: ["destinatario": .equal("ops@example.com"), "assunto": .equal("Form"), "corpo": .equal("Submitted.")]),
            ], effects: [EffectExpect(kind: "reminder", match: "Submit the form"), EffectExpect(kind: "email", match: "ops@example.com", extra: "Form")]),
            Row(language: "pt", query: "Lembrete Regar a horta daqui a 16 minutos. E-mail para horta@example.com, assunto Rega, corpo Feita às 7h.", calls: [
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Regar a horta"), "minutos": .int(16)]),
                ExpectedCall(tool: "enviarEmail", arguments: ["destinatario": .equal("horta@example.com"), "assunto": .equal("Rega"), "corpo": .equal("Feita às 7h.")]),
            ], effects: [EffectExpect(kind: "reminder", match: "Regar a horta"), EffectExpect(kind: "email", match: "horta@example.com", extra: "Rega")]),
            Row(language: "pt", query: "Sem abrir mapa: e-mail para arquivo@example.com assunto Caixa corpo Na sala 2, e lembrete Etiquetar daqui a 28 minutos.", calls: [
                ExpectedCall(tool: "enviarEmail", arguments: ["destinatario": .equal("arquivo@example.com"), "assunto": .equal("Caixa"), "corpo": .equal("Na sala 2.")]),
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Etiquetar"), "minutos": .int(28)]),
            ], effects: [EffectExpect(kind: "email", match: "arquivo@example.com", extra: "Caixa"), EffectExpect(kind: "reminder", match: "Etiquetar")]),
            Row(language: "en", query: "Email studio@example.com about Lights with body Gels are packed. Reminder Wrap cables in 65 minutes.", calls: [
                ExpectedCall(tool: "enviarEmail", arguments: ["destinatario": .equal("studio@example.com"), "assunto": .equal("Lights"), "corpo": .equal("Gels are packed.")]),
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Wrap cables"), "minutos": .int(65)]),
            ], effects: [EffectExpect(kind: "email", match: "studio@example.com", extra: "Lights"), EffectExpect(kind: "reminder", match: "Wrap cables")]),
        ]
        precondition(rows.count == 40)
        return rows.enumerated().map { index, row in
            item(String(format: "apple_multi_%03d", index + 1), row.query, "multi_tool", row.language, row.calls, "any", row.effects)
        }
    }

    private static func sequential() -> [BenchmarkTask] {
        var rows: [BenchmarkTask] = []
        func add(_ task: BenchmarkTask) { rows.append(task) }
        let people = AppleBook.people
        for (index, person) in people.enumerated() {
            let article = feminine(person.0) ? "a" : "o"
            let query = index.isMultiple(of: 2)
                ? "Ligue para \(article) \(person.0)."
                : "Call \(person.0). Use the number from the contact lookup, not a number you invent."
            add(chain(
                id: String(format: "apple_seq_%03d", rows.count + 1),
                query: query, language: index.isMultiple(of: 2) ? "pt" : "en", name: person.0, phone: person.1,
                action: "ligar", body: nil, extra: nil))
        }
        let bodies = [
            "Chego em 10 minutos.", "Estou na porta.", "Manda o código.", "Reunião cancelada.", "Pode falar agora?",
            "Deixei na recepção.", "O arquivo foi enviado.", "Atraso de cinco minutos.", "Confirmado.", "Te ligo depois.",
        ]
        for (index, person) in people.enumerated() {
            let body = bodies[index]
            let query = index.isMultiple(of: 3)
                ? "Envie uma mensagem para \(feminine(person.0) ? "a" : "o") \(person.0) dizendo \(body)"
                : "Text \(person.0): \(body) Look up the phone first."
            add(chain(
                id: String(format: "apple_seq_%03d", rows.count + 1),
                query: query, language: index.isMultiple(of: 3) ? "pt" : "en", name: person.0, phone: person.1,
                action: "enviarMensagem", body: body, extra: nil))
        }
        for person in people.prefix(8) {
            let query = rows.count.isMultiple(of: 2)
                ? "Faça uma chamada de FaceTime áudio para \(feminine(person.0) ? "a" : "o") \(person.0)."
                : "Start a FaceTime audio call with \(person.0) after you look up the number."
            add(chain(
                id: String(format: "apple_seq_%03d", rows.count + 1),
                query: query, language: rows.count.isMultiple(of: 2) ? "pt" : "en", name: person.0, phone: person.1,
                action: "ligarFaceTime", body: nil, extra: nil))
        }
        for (index, person) in people.prefix(8).enumerated() {
            let title = "Retornar \(person.0)"
            let minutes = [15, 20, 30, 40, 45, 60, 75, 90][index]
            let query = "Crie um lembrete chamado \(title) para daqui a \(minutes) minutos e depois faça uma chamada de FaceTime áudio para \(feminine(person.0) ? "a" : "o") \(person.0)."
            var calls = [
                ExpectedCall(tool: "buscarContato", arguments: ["nome": .equal(person.0)]),
                ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal(title), "minutos": .int(minutes)]),
                ExpectedCall(tool: "ligarFaceTime", arguments: ["numero": .fromCall("buscarContato", "phone")]),
            ]
            if index.isMultiple(of: 2) {
                calls = [calls[1], calls[0], calls[2]]
            }
            add(item(
                String(format: "apple_seq_%03d", rows.count + 1), query, "sequential", "pt", calls, "dependencies",
                [EffectExpect(kind: "reminder", match: title), EffectExpect(kind: "facetime", match: person.1)]))
        }
        for (index, person) in people.prefix(8).enumerated() {
            let body = "Sobre o relatório \(index + 1)."
            let title = "Relatório \(person.0)"
            let query = index < 4
                ? "Mande uma mensagem para \(feminine(person.0) ? "a" : "o") \(person.0) dizendo \(body) Também crie o evento \(title) daqui a 50 minutos; o evento não depende do telefone."
                : "Create the event \(title) in 50 minutes, and message \(person.0) saying \(body) The message needs the contact's number."
            let calls = [
                ExpectedCall(tool: "criarEvento", arguments: ["titulo": .equal(title), "minutos": .int(50)]),
                ExpectedCall(tool: "buscarContato", arguments: ["nome": .equal(person.0)]),
                ExpectedCall(tool: "enviarMensagem", arguments: [
                    "numero": .fromCall("buscarContato", "phone"), "corpo": .equal(body),
                ]),
            ]
            add(item(
                String(format: "apple_seq_%03d", rows.count + 1), query, "sequential", index < 4 ? "pt" : "en",
                calls, "dependencies",
                [EffectExpect(kind: "event", match: title), EffectExpect(kind: "message", match: person.1, extra: body)]))
        }
        for person in people.prefix(6) {
            let body = "Entro no FaceTime."
            let query = "Busque \(person.0), mande a mensagem \(body) e faça FaceTime áudio para o número encontrado. Não invente outro telefone."
            let calls = [
                ExpectedCall(tool: "buscarContato", arguments: ["nome": .equal(person.0)]),
                ExpectedCall(tool: "enviarMensagem", arguments: [
                    "numero": .fromCall("buscarContato", "phone"), "corpo": .equal(body),
                ]),
                ExpectedCall(tool: "ligarFaceTime", arguments: ["numero": .fromCall("buscarContato", "phone")]),
            ]
            add(item(
                String(format: "apple_seq_%03d", rows.count + 1), query, "sequential", "pt", calls, "dependencies",
                [EffectExpect(kind: "message", match: person.1, extra: body), EffectExpect(kind: "facetime", match: person.1)]))
        }
        precondition(rows.count == 50, "sequential \(rows.count)")
        return rows
    }

    private static func chain(
        id: String, query: String, language: String, name: String, phone: String,
        action: String, body: String?, extra: String?
    ) -> BenchmarkTask {
        var arguments: [String: ArgExpect] = ["numero": .fromCall("buscarContato", "phone")]
        if let body { arguments["corpo"] = .equal(body) }
        let effect: EffectExpect
        switch action {
        case "ligar": effect = EffectExpect(kind: "call", match: phone)
        case "ligarFaceTime": effect = EffectExpect(kind: "facetime", match: phone)
        default: effect = EffectExpect(kind: "message", match: phone, extra: body)
        }
        return item(id, query, "sequential", language, [
            ExpectedCall(tool: "buscarContato", arguments: ["nome": .equal(name)]),
            ExpectedCall(tool: action, arguments: arguments),
        ], "dependencies", [effect])
    }

    private static func ambiguous() -> [BenchmarkTask] {
        let rows: [(String, String, String)] = [
            ("pt", "Ligue para alguém.", "abstain"),
            ("en", "Call someone.", "abstain"),
            ("pt", "Ligue para o João.", "lookupOnly"),
            ("pt", "Ligue para a Rita.", "lookupOnly"),
            ("pt", "Envie um e-mail.", "abstain"),
            ("en", "Send an email.", "abstain"),
            ("pt", "Mande uma mensagem.", "abstain"),
            ("pt", "Crie um evento.", "abstain"),
            ("pt", "Crie um lembrete.", "abstain"),
            ("pt", "Abra uma rota.", "abstain"),
            ("pt", "Abra um site.", "abstain"),
            ("pt", "Ligue para a Ana ou para o Bruno.", "abstain"),
            ("en", "Call Ana or Bruno.", "abstain"),
            ("pt", "Ligue para a Ana no número +15550999.", "abstain"),
            ("pt", "Apague todos os lembretes.", "abstain"),
            ("en", "Delete my reminders.", "abstain"),
            ("pt", "Mande o e-mail de sempre para a Ana.", "abstain"),
            ("pt", "Marque com ela amanhã às 10.", "abstain"),
            ("pt", "Ligue para o contato.", "abstain"),
            ("en", "Text whoever you want.", "abstain"),
        ]
        precondition(rows.count == 20)
        return rows.enumerated().map { index, row in
            item(String(format: "apple_amb_%03d", index + 1), row.1, "ambiguous", row.0, [], "any", [], row.2)
        }
    }

    private static func feminine(_ name: String) -> Bool {
        ["Ana", "Carla", "Elena", "Marina", "Sofia"].contains(name)
    }

    /// Recorte exploratório. Queries e IDs fora do Apple 150 (residency-60 e held-out 90).
    static let stepPilot: [BenchmarkTask] = makeStepPilot()
    static var stepPilotIDs: [String] { stepPilot.map(\.id) }

    static func validateStepPilot() {
        precondition(stepPilot.count == 12)
        let ids = Set(stepPilot.map(\.id))
        precondition(ids.count == 12)
        precondition(ids.isDisjoint(with: Set(tasks.map(\.id))))
        precondition(Set(stepPilot.map(\.query)).isDisjoint(with: Set(tasks.map(\.query))))
        let kinds = Dictionary(grouping: stepPilot, by: \.category).mapValues(\.count)
        precondition(kinds["single_tool"] == 4 && kinds["multi_tool"] == 4 && kinds["sequential"] == 4, "\(kinds)")
        for task in stepPilot {
            let replay = try! TrajectoryEvaluator.replay(task)
            let report = TrajectoryEvaluator.grade(task: task, calls: replay.calls, world: replay.world)
            precondition(report.taskSuccess, "\(task.id) \(report.failureText ?? "")")
        }
    }

    private static func makeStepPilot() -> [BenchmarkTask] {
        let single: [BenchmarkTask] = [
            item("step_single_001",
                 "Acione agora uma ligação para +15550100, sem mensagem e sem FaceTime.",
                 "single_tool", "pt",
                 [ExpectedCall(tool: "ligar", arguments: ["numero": .equal("+15550100")])],
                 "exact", [EffectExpect(kind: "call", match: "+15550100")]),
            item("step_single_002",
                 "Abra somente https://www.ietf.org no Safari; não crie evento.",
                 "single_tool", "pt",
                 [ExpectedCall(tool: "abrirSafari", arguments: ["url": .equal("https://www.ietf.org")])],
                 "exact", [EffectExpect(kind: "page", match: "https://www.ietf.org")]),
            item("step_single_003",
                 "Marque na agenda o evento Standup daqui a 25 minutos.",
                 "single_tool", "pt",
                 [ExpectedCall(tool: "criarEvento", arguments: ["titulo": .equal("Standup"), "minutos": .int(25)])],
                 "exact", [EffectExpect(kind: "event", match: "Standup")]),
            item("step_single_004",
                 "Remind me in 12 minutes with the title Pack charger.",
                 "single_tool", "en",
                 [ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Pack charger"), "minutos": .int(12)])],
                 "exact", [EffectExpect(kind: "reminder", match: "Pack charger")]),
        ]
        let multi: [BenchmarkTask] = [
            item("step_multi_001",
                 "Crie o evento Standup daqui a 25 minutos e o lembrete Pack charger daqui a 12 minutos.",
                 "multi_tool", "pt",
                 [
                    ExpectedCall(tool: "criarEvento", arguments: ["titulo": .equal("Standup"), "minutos": .int(25)]),
                    ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Pack charger"), "minutos": .int(12)]),
                 ],
                 "any",
                 [EffectExpect(kind: "event", match: "Standup"), EffectExpect(kind: "reminder", match: "Pack charger")]),
            item("step_multi_002",
                 "Mande um e-mail para ana@example.com, assunto Ata, corpo Segue a ata. Também disque +15550100.",
                 "multi_tool", "pt",
                 [
                    ExpectedCall(tool: "enviarEmail", arguments: [
                        "destinatario": .equal("ana@example.com"), "assunto": .equal("Ata"), "corpo": .equal("Segue a ata."),
                    ]),
                    ExpectedCall(tool: "ligar", arguments: ["numero": .equal("+15550100")]),
                 ],
                 "any",
                 [EffectExpect(kind: "email", match: "ana@example.com", extra: "Ata"),
                  EffectExpect(kind: "call", match: "+15550100")]),
            item("step_multi_003",
                 "Open driving directions to Apple Park, Cupertino, then browse to https://www.ietf.org.",
                 "multi_tool", "en",
                 [
                    ExpectedCall(tool: "abrirRota", arguments: ["destino": .equal("Apple Park, Cupertino")]),
                    ExpectedCall(tool: "abrirSafari", arguments: ["url": .equal("https://www.ietf.org")]),
                 ],
                 "any",
                 [EffectExpect(kind: "route", match: "Apple Park, Cupertino"),
                  EffectExpect(kind: "page", match: "https://www.ietf.org")]),
            item("step_multi_004",
                 "Text +15550101 saying Chego em 10 minutos. Also remind me to Levar slides in 30 minutes.",
                 "multi_tool", "en",
                 [
                    ExpectedCall(tool: "enviarMensagem", arguments: [
                        "numero": .equal("+15550101"), "corpo": .equal("Chego em 10 minutos."),
                    ]),
                    ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Levar slides"), "minutos": .int(30)]),
                 ],
                 "any",
                 [EffectExpect(kind: "message", match: "+15550101", extra: "Chego em 10 minutos."),
                  EffectExpect(kind: "reminder", match: "Levar slides")]),
        ]
        let sequential: [BenchmarkTask] = [
            chain(id: "step_seq_001",
                  query: "Consulte a agenda, ache a Ana e só então disque o número devolvido. Não invente telefone.",
                  language: "pt", name: "Ana", phone: "+15550100", action: "ligar", body: nil, extra: nil),
            chain(id: "step_seq_002",
                  query: "Look up Bruno first, then text him: O arquivo foi enviado. Use the number from the contact lookup.",
                  language: "en", name: "Bruno", phone: "+15550101", action: "enviarMensagem",
                  body: "O arquivo foi enviado.", extra: nil),
            chain(id: "step_seq_003",
                  query: "Depois de buscar a Elena, inicie FaceTime áudio no número encontrado.",
                  language: "pt", name: "Elena", phone: "+15550104", action: "ligarFaceTime", body: nil, extra: nil),
            item("step_seq_004",
                 "Crie o lembrete Retornar Diego daqui a 40 minutos e, em seguida, faça FaceTime áudio com o Diego usando o número da agenda.",
                 "sequential", "pt",
                 [
                    ExpectedCall(tool: "criarLembrete", arguments: ["titulo": .equal("Retornar Diego"), "minutos": .int(40)]),
                    ExpectedCall(tool: "buscarContato", arguments: ["nome": .equal("Diego")]),
                    ExpectedCall(tool: "ligarFaceTime", arguments: ["numero": .fromCall("buscarContato", "phone")]),
                 ],
                 "dependencies",
                 [EffectExpect(kind: "reminder", match: "Retornar Diego"),
                  EffectExpect(kind: "facetime", match: "+15550103")]),
        ]
        return single + multi + sequential
    }
}
