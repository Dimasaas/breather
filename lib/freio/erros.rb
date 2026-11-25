# frozen_string_literal: true

class Freio
  # Sinal de "servidor indisponivel" (por exemplo, HTTP 503).
  #
  # O codigo do chamador traduz a resposta da API para esta excecao dentro do
  # bloco de Freio.executar. Se o servidor mandou Retry-After, ele vai em
  # +retry_after+ (segundos) e funciona como piso da pausa.
  class Indisponivel < StandardError
    attr_reader :retry_after

    def initialize(mensagem = "serviço indisponível", retry_after: nil)
      super(mensagem)
      @retry_after = retry_after
    end
  end

  # Levantada quando uma operacao idempotente esgota as tentativas.
  class TentativasEsgotadas < Indisponivel; end
end
