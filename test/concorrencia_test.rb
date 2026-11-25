# frozen_string_literal: true

require "test_helper"
require "apoio"

# Relogio manual: o tempo so anda quando o teste manda. O "sono" das threads
# apenas cede a vez (e conta quem esta dormindo), sem avancar o relogio.
class RelogioManual
  def initialize
    @t = 0.0
    @mutex = Mutex.new
    @dormindo = {}
  end

  def agora = @mutex.synchronize { @t }
  def avancar_para(t) = @mutex.synchronize { @t = t }

  def dormir(_segundos)
    @mutex.synchronize { @dormindo[Thread.current] = true }
    sleep 0.001
  end

  def relogio = -> { agora }
  def sono = ->(s) { dormir(s) }
  def dormindo = @mutex.synchronize { @dormindo.size }

  def esperar_dormindo(n, limite: 5)
    prazo = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limite
    sleep 0.001 while dormindo < n && Process.clock_gettime(Process::CLOCK_MONOTONIC) < prazo
    dormindo
  end
end

# Servidor falso: registra cada requisicao que "chega" com a hora simulada.
class ServidorFalso
  attr_reader :log

  def initialize(relogio, fora_ate:)
    @relogio = relogio
    @fora_ate = fora_ate
    @log = []
    @mutex = Mutex.new
  end

  def pedir
    t = @relogio.agora
    @mutex.synchronize { @log << t }
    raise Respiro::Indisponivel, "503" if t < @fora_ate

    :ok
  end

  def total = @mutex.synchronize { @log.size }
end

class ConcorrenciaTest < Minitest::Test
  N = 12

  def setup
    @rel = RelogioManual.new
    @respiro = Respiro.new(base: 5, teto: 60, fator: 2, jitter: 0,
                       relogio: @rel.relogio, dormir: @rel.sono)
    @servidor = ServidorFalso.new(@rel, fora_ate: 5)
  end

  def teardown
    @threads&.each { |t| t.kill if t.alive? }
  end

  def lancar(n, idempotente: true, &bloco)
    bloco ||= -> { @servidor.pedir }
    @threads = Array.new(n) do
      Thread.new { Respiro.executar(@respiro, idempotente: idempotente, &bloco) }
    end
  end

  # O ponto central: com a pausa aberta, NENHUMA thread dispara requisicao.
  def test_durante_a_janela_nenhuma_thread_dispara_requisicao
    @respiro.acionar!("503 inicial")
    lancar(N)

    assert_equal N, @rel.esperar_dormindo(N), "todas as threads deveriam estar esperando"
    assert_equal 0, @servidor.total, "ninguém pode ter chamado o servidor durante a pausa"

    @rel.avancar_para(4.99)
    sleep 0.05
    assert_equal 0, @servidor.total, "continua pausado até o último instante"

    @rel.avancar_para(5.0)
    resultados = @threads.map(&:value)

    assert_equal [:ok] * N, resultados
    assert_equal N, @servidor.total
    assert(@servidor.log.all? { |t| t >= 5.0 }, "todas as requisições saíram depois da pausa")
  end

  # N requisicoes ja em voo levam 503 juntas: uma pausa so, e N retentativas
  # (e nao N x tentativas).
  def test_503_simultaneos_abrem_uma_unica_pausa
    em_voo = 0
    trava = Mutex.new
    todas = ConditionVariable.new
    bloco = lambda do
      trava.synchronize do
        em_voo += 1
        todas.broadcast
        todas.wait(trava) while em_voo < N
      end
      @servidor.pedir
    end

    lancar(N, &bloco)
    @rel.esperar_dormindo(N)

    assert_equal 1, @respiro.pausas
    assert_equal 1, @respiro.seguidas
    assert_equal N, @servidor.total, "só as N requisições que já estavam em voo"

    @rel.avancar_para(5.0)
    assert_equal [:ok] * N, @threads.map(&:value)
    assert_equal 2 * N, @servidor.total
    assert_equal 0, @respiro.seguidas, "sucesso após a janela zera o backoff"
  end

  def test_thread_que_chega_no_meio_da_pausa_tambem_espera
    @respiro.acionar!
    primeira = lancar(1)
    @rel.esperar_dormindo(1)
    @threads += lancar(1)
    @rel.esperar_dormindo(2)
    assert_equal 0, @servidor.total
    @rel.avancar_para(5.0)
    assert_equal [:ok], primeira.map(&:value)
  end

  def test_pausa_expirada_nao_segura_ninguem
    @respiro.acionar!
    @rel.avancar_para(5.0)
    lancar(N)
    assert_equal [:ok] * N, @threads.map(&:value)
  end

  def test_liberar_acorda_quem_espera
    @respiro.acionar!
    lancar(N)
    @rel.esperar_dormindo(N)
    @rel.avancar_para(5.0) # o servidor já voltou
    @respiro.liberar!
    assert_equal [:ok] * N, @threads.map(&:value)
  end

  def test_contadores_consistentes_sob_disputa
    100.times do
      respiro = Respiro.new(base: 1, teto: 8, jitter: 0, relogio: @rel.relogio, dormir: @rel.sono)
      aberturas = Queue.new
      Array.new(8) { Thread.new { aberturas << respiro.acionar! } }.each(&:join)
      resultados = Array.new(aberturas.size) { aberturas.pop }
      assert_equal 1, resultados.compact.size, "só uma thread abre a pausa"
      assert_equal 1, respiro.pausas
    end
  end
end

# Com relogio e sono de verdade, em escala pequena: o respiro funciona de ponta a ponta.
class ConcorrenciaRealTest < Minitest::Test
  def test_threads_reais_atravessam_a_janela
    inicio = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    fora_ate = inicio + 0.3
    respiro = Respiro.new(base: 0.2, teto: 1, fator: 2, jitter: 0.1, fatia: 0.02)
    mutex = Mutex.new
    recusadas = 0

    threads = Array.new(8) do
      Thread.new do
        Respiro.executar(respiro, idempotente: true) do
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) < fora_ate
            mutex.synchronize { recusadas += 1 }
            raise Respiro::Indisponivel
          end
          :ok
        end
      end
    end

    assert_equal [:ok] * 8, threads.map(&:value)
    assert_operator recusadas, :<=, 16, "no máximo duas ondas de 503 (a em voo e uma de sonda)"
    assert_operator respiro.pausas, :<=, 3
  end
end
