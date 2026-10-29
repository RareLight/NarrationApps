import Foundation

/// Authored preview phrases. Language samples are not translations of user text.
public enum NarrationSampleText {
    public static func text(language: String) -> String {
        switch language {
        case "Chinese": "你好，我可以为你朗读文章和书籍。让我们一起开始新的阅读。"
        case "Japanese": "こんにちは。記事や本を自然な声で読み上げます。一緒に新しい読書を始めましょう。"
        case "Korean": "안녕하세요. 기사와 책을 자연스러운 목소리로 읽어 드릴 수 있습니다. 함께 새로운 독서를 시작해요."
        case "German": "Hallo, ich kann Artikel und Bücher vorlesen. Beginnen wir gemeinsam eine neue Geschichte."
        case "French": "Bonjour, je peux lire vos articles et vos livres. Commençons ensemble une nouvelle lecture."
        case "Russian": "Здравствуйте. Я могу читать статьи и книги. Давайте вместе начнём новую историю."
        case "Portuguese": "Olá, posso ler artigos e livros para você. Vamos começar juntos uma nova leitura."
        case "Spanish": "Hola, puedo leer artículos y libros. Empecemos juntos una nueva lectura."
        case "Italian": "Ciao, posso leggere articoli e libri. Cominciamo insieme una nuova lettura."
        default: "Hello, I can narrate everything from short articles to entire ebooks. Let's get started on a new read together!"
        }
    }
}
