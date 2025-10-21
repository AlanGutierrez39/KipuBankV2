# KipuBankV2 — README

Última actualización: 2025-10-21

## Resumen (alto nivel)

KipuBankV2 es una versión endurecida y extendida del contrato KipuBank original. Las mejoras principales son:

- Soporte multi-token: acepta ETH (nativo) y cualquier ERC-20.
- Contabilidad por token: balances por (token, usuario) en unidades del token; contabilidad económica agregada en USD.
- Límites expresados en USD: límite global del banco y límite por transacción denominados en USD (8 decimales) usando Chainlink Price Feeds.
- Control de acceso y operativa segura: AccessControl (roles), Pausable, ReentrancyGuard y SafeERC20.
- Conversión y normalización de decimales: manejo de distintos decimales de tokens y feeds; opción de override de decimales.
- Observabilidad y errores: eventos coherentes y errores personalizados para diagnósticos claros.
- Buenas prácticas de seguridad: checks-effects-interactions, manejo seguro de transferencias nativas, rechazo de ETH recibido directamente (se fuerza `depositETH()`).

Estas decisiones mejoran la seguridad, trazabilidad y extensibilidad del contrato para entornos más cercanos a producción.

---

## Qué cambié y por qué (alto nivel)

- Separé balances por token (mapping token => mapping user => uint256) para evitar mezclar unidades (wei, token-units y USD).
- Introduje variables agregadas en USD con 8 decimales (USD_DECIMALS = 8) para expresar políticas económicas (bank cap, per-tx limit) de forma independiente del token.
- Usé Chainlink Price Feeds (mapping priceFeeds) para convertir tokens→USD y así aplicar límites. address(0) se usa para identificar el feed ETH/USD.
- Añadí AccessControl (DEFAULT_ADMIN_ROLE, PAUSER_ROLE) para delegar administración y pausabilidad segura.
- Añadí SafeERC20 para transferencias ERC-20 y `.call` chequeada para ETH.
- Añadí tokenDecimalsOverride y un try/catch para tokens que no implementen `decimals()`.
- Reescribí depósitos/retiros con CEI (checks-effects-interactions), eventos claros y conteos de operaciones.

---

## Notas importantes sobre unidades y representaciones

- Las políticas económicas (cap y límites) están en "USD con 8 decimales" (p. ej. si USD_DECIMALS=8: $1 = 1e8).
  - Ejemplo: Para establecer un bank cap de $100,000 → pasar `100_000 * 10**8`.
- Los balances se almacenan en unidades del token:
  - Para ETH: unidades en wei (18 decimales).
  - Para ERC-20: unidades según los decimales del token (usando `decimals()` o el override).
- Las conversiones usan la fórmula:
  amountUsd8 = amount * priceRaw * 10**USD_DECIMALS / (10**tokenDecimals * 10**priceDecimals)
  - priceRaw y priceDecimals se obtienen del AggregatorV3Interface configurado para ese token.

---

## Instrucciones de despliegue

Requisitos previos:
- Node.js, npm.
- Hardhat o Remix.
- Clave/wallet para desplegar (recomendado multisig para admin en producción).
- ETH de prueba en la red elegida para pagar gas.
- Direcciones de Chainlink Price Feeds para la red objetivo (por ejemplo, ETH/USD).

Constructor:
- constructor(admin, initialBankCapUsd8, initialWithdrawLimitUsd8)
  - `admin`: dirección que recibirá DEFAULT_ADMIN_ROLE y PAUSER_ROLE.
  - `initialBankCapUsd8`: límite global en USD con 8 decimales (uint256).
  - `initialWithdrawLimitUsd8`: límite por transacción en USD con 8 decimales.

Ejemplo (conceptual, en Remix):
- admin = 0xYourAdminAddress
- initialBankCapUsd8 = 100_000 * 10**8  // $100,000
- initialWithdrawLimitUsd8 = 5_000 * 10**8 // $5,000

Pasos:
1. Compilar el contrato KipuBankV2.sol.
2. Desplegar con los parámetros del constructor.
3. Llamar `setPriceFeed(tokenAddress, feedAddress)` para cada token que desees aceptar:
   - Para ETH: tokenAddress = address(0), feedAddress = ETH/USD aggregator.
   - Para ERC-20 (ej. USDC): tokenAddress = USDC address, feedAddress = USDC/USD aggregator (si existe) o usar token/USD feed.
4. (Opcional) `setTokenDecimalsOverride(tokenAddress, decimals)` si el token no implementa `decimals()`.

Recomendación de despliegue:
- Use una cuenta multisig como `admin` (NO una EOA personal).
- Verifique las direcciones de Chainlink feeds para la red (Testnet vs Mainnet).
- Escribir tests y auditar antes de producción.

---

## Cómo interactuar (funciones principales)

- Depositar ETH:
  - Llamar `depositETH()` enviando ETH en el campo value.
  - Requerimientos:
    - Price feed para address(0) debe estar configurado.
    - No se acepta `msg.value == 0`.
    - No se puede exceder `s_bankCapUsd8` en USD agregado.

- Depositar ERC-20:
  - Primero: `IERC20(token).approve(contractAddress, amount)`.
  - Luego: `depositERC20(token, amount)`.
  - Requerimientos:
    - Price feed para `token` debe estar configurado.
    - No se acepta `amount == 0`.
    - No se puede exceder `s_bankCapUsd8` en USD agregado.

- Retirar ETH:
  - `withdrawETH(amountWei)`.
  - Requisitos:
    - `amountWei` ≤ balance del usuario en ETH.
    - USD equivalente ≤ `s_withdrawLimitUsd8`.
    - El contrato reduce saldo y envía `amountWei` por `.call`.

- Retirar ERC-20:
  - `withdrawERC20(token, amount)`.
  - Requisitos:
    - `amount` ≤ balance del usuario en ese token.
    - USD equivalente ≤ `s_withdrawLimitUsd8`.
    - El contrato reduce saldo y transfiere tokens con SafeERC20.

- Consultas:
  - `getBalance(token, user)` → balance en unidades del token.
  - `getUsdValue(token, amount)` → convierte a USD (8 decimales) usando el feed configurado.
  - `setPriceFeed(token, feed)` → admin, configura/actualiza el feed.
  - `pause()` / `unpause()` → PAUSER_ROLE.

Eventos a observar:
- `Deposit(token, user, amountToken, amountUsd8, newBalanceToken)`
- `Withdraw(token, user, amountToken, amountUsd8, newBalanceToken)`

---

## Decisiones de diseño y trade-offs

1. Contabilidad por token + contabilidad económica en USD (8 decimales)
   - Pros:
     - Evita mezclar unidades y ambigüedad.
     - Facilita aplicar políticas económicas (cap, límites) independientemente del token.
   - Contras:
     - Depende de oráculos para la conversión: riesgo de manipulación o staleness.
     - Operación más costosa en gas por llamadas a oráculos y cálculos.

2. Uso de Chainlink Price Feeds
   - Pros:
     - Oráculos descentralizados y ampliamente usados.
     - Facilita conversiones a USD.
   - Contras:
     - Necesidad de mantener feeds correctos por red.
     - Riesgo de feeds stale o incorrectos: se valida staleness y `price > 0`, pero hay riesgo residual.

3. USD_DECIMALS = 8 (en lugar de 6 como USDC)
   - Razón: muchos feeds Chainlink devuelven 8 decimales; escoger 8 evita conversiones innecesarias.
   - Trade-off: si quieres contabilidad en "USDC decimals" (6), deberías cambiar la constante y la fórmula.

4. AccessControl en lugar de Ownable
   - Pros:
     - Permite múltiples roles (admin, pauser).
     - Más flexible para integrarse con multisig/roles futuros.
   - Contras:
     - Mayor complejidad en integración y manejo de roles.

5. No aceptar ETH recibidos "por fuera" de depositETH
   - Diseñé `receive()` y `fallback()` para revertir, forzando el uso de `depositETH()` para que los depósitos queden registrados.
   - Trade-off: puede frustrar envíos accidentales (si alguien envía ETH por transferencia directa, será revertido). Alternativa: aceptar ETH y contabilizarlo automáticamente (pero esto requiere lógica segura y gas en receive).

6. Decimales de tokens
   - Uso `IERC20Metadata.decimals()` con try/catch y `tokenDecimalsOverride` para tokens que no lo implementen.
   - Trade-off: try/catch tiene gas adicional; override requiere administración.

7. Pausable y ReentrancyGuard
   - Se usan para mitigar emergencias y reentrancy. Recomendado mantenerlos.

8. Transferencias de ETH con `.call`
   - Pros: manejable frente a gas stipend y compatibilidad.
   - Contras: requiere comprobar el boolean `sent` y revertir si falla.

9. No hay whitelist estricta por token (actualmente cualquier token con feed puede ser depositado)
   - Pro: flexibilidad para aceptar tokens nuevos.
   - Contra: riesgo de tokens maliciosos o con feeds mal configurados. Recomendación: añadir whitelist en producción.

---

## Riesgos y recomendaciones previas a producción

- Configurar `admin` como multisig o timelock.
- Verificar y auditar las direcciones de Chainlink feeds en la red de despliegue.
- Realizar tests unitarios exhaustivos (Hardhat/Foundry) incluyendo:
  - Conversiones de decimales, oráculos stale/0 price, límites USD y reentrancy.
- Considerar añadir:
  - Lista blanca de tokens aceptados.
  - Mecanismo de emergencia (timelock + pause).
  - Funciones de rescate/recuperación (solo para admin, con auditoría).
- Auditoría externa antes de manejar fondos reales.

---

## Ejemplo rápido (uso con Remix)

1. Compilar y desplegar KipuBankV2 con:
   - admin: tu cuenta multisig o dirección de pruebas.
   - initialBankCapUsd8: `100000 * 10**8` (ej: $100k).
   - initialWithdrawLimitUsd8: `5000 * 10**8` (ej: $5k).

2. En admin:
   - `setPriceFeed(address(0), <ETH_USD_FEED_ADDRESS>)`
   - `setPriceFeed(<USDC_ADDRESS>, <USDC_USD_FEED_ADDRESS>)` (si aplica)

3. Usuario deposita ETH:
   - Abrir `depositETH()`, poner Value = 1 ether → ejecutar.

4. Usuario deposita ERC20:
   - `approve(contractAddress, amount)` en el token.
   - `depositERC20(tokenAddress, amount)`.

5. Usuario retira:
   - `withdrawETH(amountWei)` o `withdrawERC20(tokenAddress, amount)`.
