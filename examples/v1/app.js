const STORAGE_KEY = "task-tracker-tasks";

function loadTasks() {
  try {
    return JSON.parse(localStorage.getItem(STORAGE_KEY)) || [];
  } catch {
    return [];
  }
}

function saveTasks(tasks) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(tasks));
}

function render(tasks) {
  const list = document.getElementById("task-list");
  list.innerHTML = "";
  tasks.forEach((task, index) => {
    const li = document.createElement("li");
    li.className = task.done ? "done" : "";

    const span = document.createElement("span");
    span.textContent = task.text;
    span.addEventListener("click", () => {
      task.done = !task.done;
      saveTasks(tasks);
      render(tasks);
    });

    const remove = document.createElement("button");
    remove.textContent = "×";
    remove.addEventListener("click", () => {
      tasks.splice(index, 1);
      saveTasks(tasks);
      render(tasks);
    });

    li.appendChild(span);
    li.appendChild(remove);
    list.appendChild(li);
  });
}

function main() {
  const tasks = loadTasks();
  const form = document.getElementById("add-form");
  const input = document.getElementById("task-input");

  form.addEventListener("submit", (e) => {
    e.preventDefault();
    const text = input.value.trim();
    if (!text) return;
    tasks.push({ text, done: false });
    saveTasks(tasks);
    input.value = "";
    render(tasks);
  });

  render(tasks);
}

main();
