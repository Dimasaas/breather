# frozen_string_literal: true

require_relative "breather/version"
require_relative "breather/erros"

# Breather: freio global cooperativo.
#
# Varias threads compartilham UMA instancia. Quando qualquer uma delas leva um
# 503, todas passam a esperar (em #aguardar!) ate o fim da pausa, em vez de cada
# uma gastar suas proprias retentativas contra um servidor que esta fora.
#
#   breather = Breather.new(base: 5, teto: 60, fator: 2, jitter: 0.2)
#
#   Breather.executar(breather, idempotente: true) do
#     resposta = http.get("/consulta")
#     raise Breather::Indisponivel if resposta.status == 503
#     resposta
#   end
class Breather
  RELOGIO = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  DORMIR  = ->(segundos) { Kernel.sleep(segundos) }
  SORTEIO = -> { Kernel.rand }

  attr_reader :base, :teto, :fator, :jitter, :fatia

  # base:   duracao da primeira pausa, em segundos.
  # teto:   nenhuma pausa passa disso (jitter incluido).
  # fator:  multiplicador a cada pausa seguida sem sucesso no meio (>= 1).
  # jitter: fracao (0..1) somada aleatoriamente a pausa, para desalinhar clientes.
  # relogio/dormir/sorteio: injetaveis, para teste sem esperar de verdade.
  # fatia:  maior sono de uma vez; e o que permite #liberar! acordar quem espera.
  # ao_acionar: callable opcional, chamado com (motivo, duracao) a cada nova pausa.
  def initialize(base: 1.0, teto: 60.0, fator: 2.0, jitter: 0.1,
                 relogio: RELOGIO, dormir: DORMIR, sorteio: SORTEIO,
                 fatia: 0.25, ao_acionar: nil)
    raise ArgumentError, "base deve ser > 0" unless base.to_f.positive?
    raise ArgumentError, "teto deve ser >= base" if teto.to_f < base.to_f
    raise ArgumentError, "fator deve ser >= 1" if fator.to_f < 1
    raise ArgumentError, "jitter deve estar entre 0 e 1" unless (0..1).cover?(jitter.to_f)
    raise ArgumentError, "fatia deve ser > 0" unless fatia.to_f.positive?

    @base, @teto, @fator, @jitter, @fatia = base.to_f, teto.to_f, fator.to_f, jitter.to_f, fatia.to_f
    @relogio    = relogio
    @dormir     = dormir
    @sorteio    = sorteio
    @ao_acionar = ao_acionar
    @mutex      = Mutex.new
    @pausado_ate = nil
    @seguidas    = 0
    @pausas      = 0
  end

  # Quantas pausas ja foram abertas nesta instancia.
  def pausas = @mutex.synchronize { @pausas }

  # Pausas seguidas sem nenhum sucesso entre elas (define o backoff).
  def seguidas = @mutex.synchronize { @seguidas }

  def pausado? = @mutex.synchronize { restante_sem_trava.positive? }

  # Segundos que faltam para a pausa atual terminar (0 se nao ha pausa).
  def restante = @mutex.synchronize { restante_sem_trava }

  # Bloqueia a thread enquanto houver pausa. Devolve true se esperou algo.
  # Chamar antes de CADA requisicao, nao so da primeira.
  def aguardar!
    esperou = false
    loop do
      resta = restante
      break unless resta.positive?

      @dormir.call([resta, @fatia].min)
      esperou = true
    end
    esperou
  end

  # Abre uma pausa global. Devolve a duracao (segundos) da pausa aberta, ou nil
  # se ja havia uma pausa em curso: varios 503 da MESMA janela nao escalam o
  # backoff, senao N threads dobrariam o tempo N vezes.
  #
  # espera: piso opcional (ex.: Retry-After do servidor); ainda respeita o teto.
  def acionar!(motivo = nil, espera: nil)
    duracao = nil
    @mutex.synchronize do
      next if restante_sem_trava.positive?

      duracao = calcular_duracao(espera)
      @pausado_ate = @relogio.call + duracao
      @seguidas += 1
      @pausas += 1
    end
    @ao_acionar&.call(motivo, duracao) if duracao
    duracao
  end

  # Encerra a pausa agora e zera o backoff. Quem espera acorda na proxima fatia.
  def liberar!
    @mutex.synchronize do
      @pausado_ate = nil
      @seguidas = 0
    end
    nil
  end

  # Registra uma resposta boa: zera o backoff, mas nao mexe numa pausa em curso
  # (uma resposta que estava em voo antes do 503 nao prova que a janela passou).
  def sucesso!
    @mutex.synchronize { @seguidas = 0 unless restante_sem_trava.positive? }
    nil
  end

  # Roda o bloco respeitando o breather.
  #
  # idempotente: true  -> um Breather::Indisponivel aciona o breather e a operacao e
  #                       refeita (ate +tentativas+ no total).
  # idempotente: false -> aciona o breather para as OUTRAS threads, mas relanca o
  #                       erro: uma escrita nunca e repetida sozinha.
  def self.executar(breather, idempotente: false, tentativas: 4)
    raise ArgumentError, "tentativas deve ser >= 1" if tentativas < 1

    feitas = 0
    begin
      breather.aguardar!
      feitas += 1
      resultado = yield
      breather.sucesso!
      resultado
    rescue Indisponivel => e
      breather.acionar!(e.message, espera: e.retry_after)
      raise unless idempotente
      raise TentativasEsgotadas.new(e.message, retry_after: e.retry_after) if feitas >= tentativas

      retry
    end
  end

  private

  def restante_sem_trava
    return 0.0 unless @pausado_ate

    [@pausado_ate - @relogio.call, 0.0].max
  end

  # Chamado com a trava tomada (@seguidas ainda e o valor ANTES desta pausa).
  def calcular_duracao(piso)
    bruta = @base * (@fator**@seguidas)
    bruta = [bruta, piso.to_f].max if piso
    com_jitter = bruta * (1 + (@jitter * @sorteio.call))
    [com_jitter, @teto].min
  end
end
