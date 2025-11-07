# KipuBankV3
# 🏦 KipuBankV3 — DeFi Smart Contract con integración a Uniswap V2

## 📘 Descripción General

`KipuBankV3` es una evolución del contrato `KipuBankV2`, diseñado para convertirlo en una aplicación DeFi más realista y composable.  
Esta nueva versión introduce soporte para **depósitos en múltiples tokens ERC20**, los cuales son automáticamente intercambiados a **USDC** mediante el **router de Uniswap V2**, respetando al mismo tiempo el **límite máximo de fondos (bankCap)** del banco.

---

## 🚀 Mejoras Implementadas

### 1. ✅ Soporte para múltiples tokens ERC20
Los usuarios ya no están limitados a depositar solo ETH o USDC.  
Cualquier token con par directo en Uniswap V2 contra USDC puede ser depositado, y el contrato realizará el **swap automáticamente a USDC**.

### 2. 🔄 Integración con Uniswap V2 Router
El contrato usa el **enrutador de Uniswap V2** para ejecutar los intercambios dentro del propio smart contract, sin necesidad de intervención externa.

Esto permite:
- Recibir tokens diversos (por ejemplo, DAI, LINK, WBTC).
- Convertirlos automáticamente en USDC.
- Mantener los balances internos en una sola unidad estable (USDC).

### 3. 💰 Preservación de la lógica de `KipuBankV2`
Se mantienen todas las funcionalidades del banco:
- Control del `owner`
- Depósitos y retiros
- Control de límite máximo (`bankCap`)

### 4. 🛡️ Seguridad y Buenas Prácticas
- Uso de `ReentrancyGuard` para prevenir ataques de reentrada.
- Validación de valores de entrada.
- Restricciones de acceso mediante `onlyOwner`.
- Aprobaciones seguras y limpieza de allowance tras swaps.

---

## ⚙️ Parámetros del Constructor

Al desplegar el contrato en Remix, se debe completar el **constructor** con los siguientes parámetros:

```solidity
constructor(
    address _usdc,
    address _uniswapV2Router,
    uint256 _bankCap
)

| Parámetro          | Descripción                                                                                                                                | Ejemplo (Red Sepolia)                                                     |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| `_usdc`            | Dirección del contrato ERC20 del token USDC (o equivalente de prueba). Es el token estable en el cual se mantienen los balances del banco. | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`                              |
| `_uniswapV2Router` | Dirección del router de Uniswap V2 (usado para swaps).                                                                                     | `0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3` (Sepolia testnet)            |
| `_bankCap`         | Monto máximo total en USDC que puede tener el banco.                                                                                       | `1000000000000` (equivale a 1,000,000 USDC si el token tiene 6 decimales) |

```
Ejemplo:
Para deployar este contrato utilice las siguientes direcciones:

router:0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45

token usdc de prueba:0x2f3A40A3db8a7e3D09B0adfEfbCe4f6F81927557
